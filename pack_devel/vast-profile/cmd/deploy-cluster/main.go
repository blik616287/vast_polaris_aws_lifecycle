// deploy-cluster provisions (or re-provisions) a Palette-managed AWS Kubernetes
// cluster bound to the vast-storage cluster profile, filling the VMS connection
// details as cluster variables at create time.
//
// Modeled on ../cmargo/cluster-profile/cmd/deploy-cluster, adapted from edge-native
// to a managed AWS IaaS cluster: resolve the AWS cloud account + the published
// profile, (optionally) delete an existing same-named cluster, then CreateClusterAws
// with a control-plane + worker machine pool and the profile's VMS variables.
//
// Run from vast-profile/:
//
//	PALETTE_API_KEY=<token> \
//	CLOUD_ACCOUNT=<aws-account-name-in-palette> \
//	SSH_KEY_NAME=<ec2-keypair> \
//	VMS_ENDPOINT=https://<VMS-VIP> VMS_USERNAME=<u> VMS_PASSWORD=<p> \
//	VAST_VIP_POOL=<pool> VAST_STORAGE_PATH=/k8s/tenant-a \
//	go run ./cmd/deploy-cluster
//
// Env:
//
//	PALETTE_API_KEY  (required)  Palette API key
//	PALETTE_HOST     Palette host (default palette.isc-spectro-dev.click)
//	PALETTE_PROJECT  project UID to scope to (optional)
//	CLUSTER_NAME     cluster name (default vast-storage-aws)
//	PROFILE_UID      cluster profile to bind; if unset, resolves the newest
//	                 published version of PROFILE_NAME
//	PROFILE_NAME     profile name to resolve when PROFILE_UID unset (default vast-storage)
//	REDEPLOY         "1" to delete an existing same-named cluster first (default off)
//
//	-- AWS placement --
//	CLOUD_ACCOUNT    (required)  AWS cloud-account name registered in Palette
//	REGION           AWS region (default us-east-2)
//	SSH_KEY_NAME     EC2 key pair name for node access (optional but recommended)
//	VPC_ID           bring-your-own VPC id (peered to the VAST VPC); omit for a managed VPC
//	AZS              comma-separated AZs for the worker pool (default <region>a)
//	SUBNET_IDS       comma-separated subnet ids, paired positionally with AZS (BYO-VPC)
//	CP_INSTANCE_TYPE control-plane instance type (default m5.large)
//	CP_COUNT         control-plane node count (default 1)
//	WORKER_INSTANCE_TYPE worker instance type (default m5.xlarge)
//	WORKER_COUNT     worker node count (default 2)
//
//	-- VMS variables (fed to the profile; same names as create-profile) --
//	VMS_ENDPOINT*, VMS_USERNAME*, VMS_PASSWORD*, VAST_VIP_POOL*, VAST_STORAGE_PATH*,
//	VAST_VIEW_POLICY (default "default"), VAST_QOS_POLICY (optional)
package main

import (
	"fmt"
	"log"
	"os"
	"strconv"
	"strings"

	"github.com/spectrocloud/palette-sdk-go/api/models"
	"github.com/spectrocloud/palette-sdk-go/client"
	"github.com/spectrocloud/palette-sdk-go/client/apiutil"
)

const defaultPaletteHost = "palette.isc-spectro-dev.click"

func envOr(k, def string) string {
	if v := os.Getenv(k); v != "" {
		return v
	}
	return def
}

func mustEnv(k string) string {
	v := os.Getenv(k)
	if v == "" {
		log.Fatalf("%s is required", k)
	}
	return v
}

func atoi32(s string, def int32) int32 {
	if s == "" {
		return def
	}
	n, err := strconv.Atoi(s)
	if err != nil {
		log.Fatalf("invalid int %q: %v", s, err)
	}
	return int32(n)
}

func main() {
	apiKey := mustEnv("PALETTE_API_KEY")
	host := envOr("PALETTE_HOST", defaultPaletteHost)
	clusterName := envOr("CLUSTER_NAME", "vast-storage-aws")
	region := envOr("REGION", "us-east-2")

	opts := []func(*client.V1Client){client.WithPaletteURI(host), client.WithAPIKey(apiKey)}
	if proj := os.Getenv("PALETTE_PROJECT"); proj != "" {
		opts = append(opts, client.WithScopeProject(proj))
	}
	pc := client.New(opts...)

	// Resolve the profile to bind.
	profileUID := os.Getenv("PROFILE_UID")
	if profileUID == "" {
		name := envOr("PROFILE_NAME", "vast-storage")
		var err error
		profileUID, err = newestProfileUID(pc, name)
		if err != nil {
			log.Fatalf("resolving profile %q: %v (set PROFILE_UID explicitly)", name, err)
		}
		log.Printf("resolved profile %q -> uid=%s", name, profileUID)
	}

	// Resolve the AWS cloud account by name.
	acctName := mustEnv("CLOUD_ACCOUNT")
	acct, err := pc.GetCloudAccountAwsByName(acctName, "")
	if err != nil {
		log.Fatalf("AWS cloud account %q: %v", acctName, err)
	}
	if acct.Metadata == nil || acct.Metadata.UID == "" {
		log.Fatalf("AWS cloud account %q has no uid", acctName)
	}
	log.Printf("cloud account %q -> uid=%s", acctName, acct.Metadata.UID)

	// Optional delete-then-redeploy.
	if os.Getenv("REDEPLOY") == "1" {
		if existing, e := pc.GetClusterByName(clusterName, false); e == nil && existing.Metadata != nil {
			log.Printf("deleting existing cluster %s (%s)...", clusterName, existing.Metadata.UID)
			if e := pc.DeleteCluster(existing.Metadata.UID); e != nil {
				log.Printf("delete returned: %v (continuing)", e)
			}
		} else {
			log.Printf("no existing cluster %q to delete (continuing)", clusterName)
		}
	}

	cluster := buildCluster(clusterName, region, acct.Metadata.UID, profileUID)
	uid, err := pc.CreateClusterAws(cluster)
	if err != nil {
		log.Fatalf("creating AWS cluster: %v", err)
	}
	log.Printf("created AWS cluster %q uid=%s", clusterName, uid)
	fmt.Printf("\nCluster created: %s\n", uid)
	if proj := os.Getenv("PALETTE_PROJECT"); proj != "" {
		fmt.Printf("Watch: https://%s/projects/%s/clusters/%s/overview\n", host, proj, uid)
	} else {
		fmt.Printf("Watch: https://%s/clusters/%s/overview\n", host, uid)
	}
}

func buildCluster(name, region, cloudAcctUID, profileUID string) *models.V1SpectroAwsClusterEntity {
	azs := splitCSV(envOr("AZS", region+"a"))

	// parseSubnets turns "subnet-id" (paired positionally with AZS) or "subnet-id@az"
	// tokens into the per-pool subnet list. Palette stores subnetIds as a {az:id} map
	// (one per AZ per pool), and the cluster network is the UNION of all pools' subnets.
	parseSubnets := func(csv string) []*models.V1AwsSubnetEntity {
		toks := splitCSV(csv)
		out := make([]*models.V1AwsSubnetEntity, 0, len(toks))
		for i, tok := range toks {
			id, az := tok, ""
			if k := strings.IndexByte(tok, '@'); k >= 0 {
				id, az = tok[:k], tok[k+1:]
			} else if i < len(azs) {
				az = azs[i]
			}
			// Palette stores subnetIds as {az: "id1,id2"} — multiple subnets per AZ
			// are comma-joined in ONE entry. To put a private subnet (CP/worker node)
			// AND a public subnet (internet-facing API LB) in the same AZ, join them
			// with '+' in the token: "subnet-priv+subnet-pub@az".
			id = strings.ReplaceAll(id, "+", ",")
			out = append(out, &models.V1AwsSubnetEntity{ID: id, Az: az})
		}
		return out
	}

	// CAPA places control-plane/worker nodes in PRIVATE subnets, but the default
	// internet-facing API LB needs PUBLIC subnets — and Palette's management plane
	// must reach that LB (so it can't be internal). Since a pool's subnetIds is one
	// per AZ, put the CP pool in PRIVATE subnets (CP nodes) and the worker pool in
	// PUBLIC subnets, so the cluster network (union) has BOTH: the LB lands on the
	// public ones, the CP node on the private ones. CP_SUBNET_IDS / WORKER_SUBNET_IDS
	// override; both fall back to SUBNET_IDS.
	base := os.Getenv("SUBNET_IDS")
	cpSubnets := parseSubnets(envOr("CP_SUBNET_IDS", base))
	// Workers don't host the API LB, so they must NOT inherit the CP pool's
	// comma-joined private+public subnet: CAPA cannot build a worker AWSMachineTemplate
	// from two subnets in one AZ, so the worker pool silently never provisions (Palette
	// shows it "provisioning" forever with 0 worker machines). Use the FIRST (private)
	// subnet per AZ for workers.
	wkSubnets := parseSubnets(envOr("WORKER_SUBNET_IDS", base))
	for _, s := range wkSubnets {
		if i := strings.IndexByte(s.ID, ','); i >= 0 {
			s.ID = s.ID[:i]
		}
	}

	mpCloud := func(instanceType string, subnets []*models.V1AwsSubnetEntity) *models.V1AwsMachinePoolCloudConfigEntity {
		c := &models.V1AwsMachinePoolCloudConfigEntity{
			InstanceType: apiutil.Ptr(instanceType),
			// Palette doc default is 60GB; the API does NOT apply that default, so an
			// unset (0) rootDeviceSize yields an invalid AWSMachineTemplate for a worker
			// MachineDeployment (the worker Machine then never launches an EC2).
			RootDeviceSize: int64(atoi32(os.Getenv("ROOT_DISK_GB"), 60)),
		}
		// BYO subnets define placement. Palette ALSO requires the pool-level Azs to be
		// set (and validates that the worker pool's Azs are a subset of the CP pool's),
		// so derive the AZ list from the subnets and set both. (An earlier note claimed
		// setting Azs makes CAPA seek managed subnets — that was wrong; the AwsWorkerPool
		// AzsValidate check fails WITHOUT pool Azs, and a worker MachineDeployment never
		// creates a Machine when its AZ failure-domain is unset.)
		if len(subnets) > 0 {
			c.Subnets = subnets
			seen := map[string]bool{}
			for _, s := range subnets {
				if s.Az != "" && !seen[s.Az] {
					c.Azs = append(c.Azs, s.Az)
					seen[s.Az] = true
				}
			}
		} else {
			c.Azs = azs
		}
		return c
	}

	cpSize := atoi32(os.Getenv("CP_COUNT"), 1)
	wkSize := atoi32(os.Getenv("WORKER_COUNT"), 2)
	// WORKER_COUNT=0 -> SINGLE-NODE cluster: the control plane ALSO runs workloads
	// (useControlPlaneAsWorker removes the control-plane NoSchedule taint) and no
	// worker pool is created. This is how a 1-node VAST test cluster schedules the
	// CSI/COSI/block driver pods, and it sidesteps the worker-MachineDeployment path.
	singleNode := wkSize == 0

	pools := []*models.V1AwsMachinePoolConfigEntity{
		{
			CloudConfig: mpCloud(envOr("CP_INSTANCE_TYPE", "m5.large"), cpSubnets),
			PoolConfig: &models.V1MachinePoolConfigEntity{
				Name:                    apiutil.Ptr("cp-pool"),
				IsControlPlane:          true,
				UseControlPlaneAsWorker: singleNode,
				Labels:                  []string{"control-plane"},
				Size:                    &cpSize,
				MinSize:                 cpSize,
				MaxSize:                 cpSize,
			},
		},
	}
	if !singleNode {
		pools = append(pools, &models.V1AwsMachinePoolConfigEntity{
			CloudConfig: mpCloud(envOr("WORKER_INSTANCE_TYPE", "m5.xlarge"), wkSubnets),
			PoolConfig: &models.V1MachinePoolConfigEntity{
				// Worker pool hosts the VAST CSI/COSI/block driver pods; keep it in the
				// AZ(s) of the VAST VIP pool so the data path stays same-AZ.
				Name:    apiutil.Ptr("worker-pool"),
				Labels:  []string{"worker"},
				Size:    &wkSize,
				MinSize: wkSize,
				MaxSize: wkSize,
			},
		})
	}

	cloudConfig := &models.V1AwsClusterConfig{
		Region:     apiutil.Ptr(region),
		SSHKeyName: os.Getenv("SSH_KEY_NAME"),
		VpcID:      os.Getenv("VPC_ID"),
		// LEAVE EMPTY ("") => internet-facing API LB. The Palette MANAGEMENT plane
		// (CAPI controllers) must reach the workload API to mark the control plane
		// Ready; an "internal" LB is unreachable from the mgmt VPC, so CAPI loops
		// terminating+recreating CP nodes forever (kubeadm init succeeds but the
		// machine never goes Ready). Working clusters (e.g. vast-test-2651) use
		// internet-facing. Only set "internal" if the mgmt plane is in/peered to the
		// node VPC AND routed to the internal LB. Needs public subnets (priv+pub@az).
		ControlPlaneLoadBalancer: os.Getenv("CONTROL_PLANE_LB"),
		// Raw CAPI override (YAML), merged into the generated AWSCluster. Used to pin
		// the API LB to PUBLIC subnets while the machine pools stay PRIVATE — the only
		// way to get an internet-facing LB + all-private nodes in a BYO VPC. Supply via
		// OVERRIDE_CAPI (raw) or OVERRIDE_CAPI_FILE (path).
		OverrideClusterAPIConfig: readOverride(),
	}

	return &models.V1SpectroAwsClusterEntity{
		Metadata: &models.V1ObjectMeta{
			Name:   name,
			Labels: map[string]string{"app": "vast", "managed-by": "vast-profile"},
		},
		Spec: &models.V1SpectroAwsClusterEntitySpec{
			CloudAccountUID:   apiutil.Ptr(cloudAcctUID),
			CloudConfig:       cloudConfig,
			Machinepoolconfig: pools,
			Profiles: []*models.V1SpectroClusterProfileEntity{
				{UID: profileUID, Variables: profileVariables()},
			},
		},
	}
}

// profileVariables returns the VMS variable bindings, unless SKIP_VARS=1 (for
// infra-only profiles that declare no variables, e.g. an imported infra profile).
func profileVariables() []*models.V1SpectroClusterVariable {
	if os.Getenv("SKIP_VARS") == "1" {
		return nil
	}
	return vmsVariableValues()
}

// vmsVariableValues maps the VMS env vars to the profile variables defined in
// create-profile. Required ones are validated; optional ones are sent only when set.
func vmsVariableValues() []*models.V1SpectroClusterVariable {
	v := func(name, val string) *models.V1SpectroClusterVariable {
		return &models.V1SpectroClusterVariable{Name: apiutil.Ptr(name), Value: val}
	}
	vars := []*models.V1SpectroClusterVariable{
		v("vmsEndpoint", mustEnv("VMS_ENDPOINT")),
		v("vmsUsername", mustEnv("VMS_USERNAME")),
		v("vmsPassword", mustEnv("VMS_PASSWORD")),
		v("vastVipPool", mustEnv("VAST_VIP_POOL")),
		v("vastStoragePath", mustEnv("VAST_STORAGE_PATH")),
		v("vastViewPolicy", envOr("VAST_VIEW_POLICY", "default")),
		// vast-block NVMe-TCP subsystem = the VAST view name (protocols:["BLOCK"])
		// created by vast-tenancy; default matches the tenancy default.
		v("vastBlockSubsystem", envOr("VAST_BLOCK_SUBSYSTEM", "k8s-block")),
	}
	if q := os.Getenv("VAST_QOS_POLICY"); q != "" {
		vars = append(vars, v("vastQosPolicy", q))
	}
	return vars
}

// newestProfileUID returns the uid of the highest-version profile named `name`.
func newestProfileUID(pc *client.V1Client, name string) (string, error) {
	profiles, err := pc.GetClusterProfiles()
	if err != nil {
		return "", err
	}
	var bestUID, bestVer string
	for _, p := range profiles {
		if p.Metadata == nil || p.Metadata.Name != name || p.Spec == nil {
			continue
		}
		if bestUID == "" || versionLess(bestVer, p.Spec.Version) {
			bestUID, bestVer = p.Metadata.UID, p.Spec.Version
		}
	}
	if bestUID == "" {
		return "", fmt.Errorf("no published profile named %q", name)
	}
	return bestUID, nil
}

func versionLess(a, b string) bool {
	pa, pb := strings.Split(a, "."), strings.Split(b, ".")
	for i := 0; i < 3; i++ {
		na, nb := atoiAt(pa, i), atoiAt(pb, i)
		if na != nb {
			return na < nb
		}
	}
	return false
}

func atoiAt(parts []string, i int) int {
	if i >= len(parts) {
		return 0
	}
	n, _ := strconv.Atoi(strings.TrimFunc(parts[i], func(r rune) bool { return r < '0' || r > '9' }))
	return n
}

// readOverride returns the CAPI override YAML from OVERRIDE_CAPI or OVERRIDE_CAPI_FILE.
func readOverride() string {
	if f := os.Getenv("OVERRIDE_CAPI_FILE"); f != "" {
		if b, err := os.ReadFile(f); err == nil {
			return string(b)
		} else {
			log.Fatalf("reading OVERRIDE_CAPI_FILE %q: %v", f, err)
		}
	}
	return os.Getenv("OVERRIDE_CAPI")
}

func splitCSV(s string) []string {
	if strings.TrimSpace(s) == "" {
		return nil
	}
	out := []string{}
	for _, p := range strings.Split(s, ",") {
		if p = strings.TrimSpace(p); p != "" {
			out = append(out, p)
		}
	}
	return out
}
