// create-profile builds and publishes a Palette cluster profile that layers the
// three VAST Data add-on packs (vast-csi / vast-cosi / vast-block) on top of an
// AWS-managed Kubernetes cluster, with the VMS connection details exposed as
// sensitive profile variables (filled per-cluster at deploy time, never baked in).
//
// Modeled on ../cmargo/cluster-profile/cmd/create-profile but generalized:
//   - pack UIDs are RESOLVED FROM THE REGISTRY by name (not hardcoded), so a
//     `upload.sh` push + Palette sync is all that's needed before running this;
//   - secrets live only in Palette variables + a vast-mgmt Secret manifest layer.
//
// Run from vast-profile/:
//
//	PALETTE_API_KEY=<token> go run ./cmd/create-profile
//
// Env:
//
//	PALETTE_API_KEY   (required) Palette API key for palette.isc-spectro-dev.click
//	PALETTE_HOST      Palette host (default palette.isc-spectro-dev.click)
//	PALETTE_PROJECT   project UID to scope to (optional; default tenant scope)
//	ISC_REGISTRY_UID  ISC pack registry UID holding the VAST packs
//	                  (default 6a29d1b56365d069e5ac1d81, from pack_devel/upload.sh)
//	ISC_REGISTRY_NAME registry display name to resolve the UID by, if UID unset
//	                  (default "spectro-packs")
//	PROFILE_NAME      cluster profile name (default vast-storage)
//	PROFILE_TYPE      "add-on" (default) or "cluster".
//	                    add-on  -> portable storage profile (cloudType all),
//	                               just the VAST packs + vast-mgmt secret; attach
//	                               it to any existing AWS/EKS cluster profile.
//	                    cluster -> full AWS infra stack + VAST packs. Infra layers
//	                               are resolved from PUBLIC_REGISTRY by name; set
//	                               INFRA_* overrides if your registry differs.
//	PUBLIC_REGISTRY   registry name for the AWS infra layers in cluster mode
//	                  (default "Public Repo")
package main

import (
	"crypto/sha1"
	"encoding/json"
	"fmt"
	"log"
	"os"
	"strconv"
	"strings"

	"github.com/spectrocloud/palette-sdk-go/api/models"
	"github.com/spectrocloud/palette-sdk-go/client"
	"github.com/spectrocloud/palette-sdk-go/client/apiutil"
)

// ---- configuration knobs (env-overridable) -------------------------------

func envOr(key, def string) string {
	if v := os.Getenv(key); v != "" {
		return v
	}
	return def
}

const (
	defaultISCRegistryUID = "6a29d1b56365d069e5ac1d81" // ISC Palette Registry (pack_devel/upload.sh)
	defaultPaletteHost    = "palette.isc-spectro-dev.click"
)

// packDef is one layer in the profile. Registry packs are resolved by name+tag
// against a registry; manifest-only layers carry raw YAML and no chart.
type packDef struct {
	name       string
	layer      models.V1PackLayer
	tagGlob    string // version tag to select, e.g. "2.6.5" or "1.30.x"; "" = newest
	regUID     string // registry to resolve from; "" for manifestOnly
	valuesFile string // path (relative to vast-profile/) to the values override; "" = none

	manifestOnly bool
	manifests    []manifestDef
}

type manifestDef struct {
	name string
	file string
}

func main() {
	apiKey := os.Getenv("PALETTE_API_KEY")
	if apiKey == "" {
		log.Fatal("PALETTE_API_KEY is required")
	}
	host := envOr("PALETTE_HOST", defaultPaletteHost)
	profileName := envOr("PROFILE_NAME", "vast-storage")
	profileTypeStr := envOr("PROFILE_TYPE", "add-on")

	opts := []func(*client.V1Client){client.WithPaletteURI(host), client.WithAPIKey(apiKey)}
	if proj := os.Getenv("PALETTE_PROJECT"); proj != "" {
		opts = append(opts, client.WithScopeProject(proj))
	}
	pc := client.New(opts...)

	// Resolve the ISC registry UID (holds the VAST packs).
	iscReg := os.Getenv("ISC_REGISTRY_UID")
	if iscReg == "" {
		iscReg = defaultISCRegistryUID
		if name := os.Getenv("ISC_REGISTRY_NAME"); name != "" {
			if reg, err := pc.GetPackRegistryByName(name); err == nil && reg.Metadata != nil && reg.Metadata.UID != "" {
				iscReg = reg.Metadata.UID
			} else if err != nil {
				log.Printf("warn: could not resolve ISC registry %q by name (%v) — using %s", name, err, iscReg)
			}
		}
	}
	log.Printf("ISC registry (VAST packs): %s", iscReg)

	// The three VAST add-on layers — resolved from the ISC registry by name.
	// VAST_PACK_TAG selects the pack version (the iterative release workflow sets
	// it to the freshly published minor version).
	//
	// Default is the "-4" revision, NOT the base "2.6.5": the base revision does
	// not bundle the prerequisite CRDs, so vast-csi (VolumeSnapshotClass) and
	// vast-cosi (BucketClass) fail to install with "ensure CRDs are installed
	// first". The "-N" revisions bundle snapshot.storage.k8s.io + objectstorage.k8s.io
	// CRDs (verified: revision -4 installs them and all three packs run green).
	vastTag := envOr("VAST_PACK_TAG", "2.6.5-4")
	layers := []packDef{
		{name: "vast-csi", layer: models.V1PackLayerAddon, tagGlob: vastTag, regUID: iscReg, valuesFile: "packs/vast-csi-values.yaml"},
		{name: "vast-cosi", layer: models.V1PackLayerAddon, tagGlob: vastTag, regUID: iscReg, valuesFile: "packs/vast-cosi-values.yaml"},
		{name: "vast-block", layer: models.V1PackLayerAddon, tagGlob: vastTag, regUID: iscReg, valuesFile: "packs/vast-block-values.yaml"},
		{
			// vast-mgmt credentials Secret (+ namespaces) as a raw-manifest layer.
			name:         "vast-mgmt-secret",
			layer:        models.V1PackLayerAddon,
			manifestOnly: true,
			manifests:    []manifestDef{{name: "vast-mgmt-secret", file: "manifests/vast-mgmt-secret.yaml"}},
		},
	}

	var (
		cloudType   string
		profileType models.V1ProfileType
	)
	switch profileTypeStr {
	case "infra":
		// Infra-only AWS cluster profile (OS/k8s/CNI/CSI) — reproduces the working
		// imported profile, no VAST addons, no variables.
		cloudType = "aws"
		profileType = models.V1ProfileTypeCluster
		layers = awsInfraLayers(pc)
	case "cluster":
		// Full AWS cluster profile: prepend the infra stack (OS/k8s/CNI/CSI).
		cloudType = "aws"
		profileType = models.V1ProfileTypeCluster
		layers = append(awsInfraLayers(pc), layers...)
	case "add-on", "addon", "add-On":
		// Portable storage add-on profile, attachable to any AWS/EKS cluster.
		cloudType = "all"
		profileType = models.V1ProfileTypeAddDashOn
	default:
		log.Fatalf("PROFILE_TYPE must be \"add-on\" or \"cluster\" (got %q)", profileTypeStr)
	}
	log.Printf("building %s profile %q (cloudType=%s)", profileTypeStr, profileName, cloudType)

	packs, err := buildPacks(pc, layers)
	if err != nil {
		log.Fatalf("building packs: %v", err)
	}

	version := nextVersion(pc, profileName)
	log.Printf("profile %q -> version %s, %d layers", profileName, version, len(packs))

	profile := &models.V1ClusterProfileEntity{
		Metadata: &models.V1ObjectMeta{
			Name:   profileName,
			Labels: map[string]string{"app": "vast", "managed-by": "vast-profile"},
		},
		Spec: &models.V1ClusterProfileEntitySpec{
			Version: version,
			Template: &models.V1ClusterProfileTemplateDraft{
				CloudType: cloudType,
				Type:      &profileType,
				Packs:     packs,
			},
			// Variables must be in the create payload — the packs' {{.spectro.var.*}}
			// references are validated against them at create time. Infra-only has none.
			Variables: func() []*models.V1Variable {
				if profileTypeStr == "infra" {
					// Reproduce the working profile's variable set (defaults only).
					return loadInfraVariables()
				}
				if profileTypeStr == "cluster" {
					// A FULL profile carries both the infra OS/k8s packs (which declare
					// {{.spectro.var.*}} DPU/SRIOV/etc. variables) AND the VAST packs
					// (VMS variables) — the create payload must define BOTH, or Palette
					// rejects it with PackVariablesUndefined on the OS pack.
					return append(loadInfraVariables(), vmsVariables()...)
				}
				return vmsVariables()
			}(),
		},
	}

	uid, err := pc.CreateClusterProfile(profile)
	if err != nil {
		log.Fatalf("creating cluster profile: %v", err)
	}
	if err := pc.PublishClusterProfile(uid); err != nil {
		log.Fatalf("publishing cluster profile: %v", err)
	}

	// Confirm the variables landed (the published summary doesn't echo them; the
	// dedicated variables endpoint is authoritative).
	if vars, e := pc.GetProfileVariables(uid); e == nil {
		names := make([]string, 0, len(vars))
		for _, v := range vars {
			if v.Name != nil {
				names = append(names, *v.Name)
			}
		}
		log.Printf("profile variables: %v", names)
	}
	log.Printf("published cluster profile %q version %s uid=%s", profileName, version, uid)
	fmt.Printf("\nCluster profile ready: %s (%s v%s)\n", uid, profileName, version)
}

// loadInfraVariables loads the infra profile's variables (infra/variables.json,
// extracted from the working profile export) so the packs' {{.spectro.var.*}}
// references validate at create. Returns nil if the file is absent.
func loadInfraVariables() []*models.V1Variable {
	b, err := os.ReadFile("infra/variables.json")
	if err != nil {
		return nil
	}
	var vars []*models.V1Variable
	if err := json.Unmarshal(b, &vars); err != nil {
		log.Fatalf("parsing infra/variables.json: %v", err)
	}
	return vars
}

// vmsVariables are the per-cluster inputs the VAST packs + vast-mgmt secret
// reference as {{.spectro.var.NAME}}. Sensitive ones are stored encrypted and
// prompted at cluster-create; nothing is hardcoded into the published profile.
func vmsVariables() []*models.V1Variable {
	str := models.V1VariableFormatString
	v := func(name, display, desc string, sensitive bool) *models.V1Variable {
		return &models.V1Variable{
			Name: apiutil.Ptr(name), DisplayName: display, Description: desc,
			Format: &str, IsSensitive: sensitive, Required: !sensitive,
		}
	}
	return []*models.V1Variable{
		v("vmsEndpoint", "VAST VMS Endpoint", "VMS management VIP as a BARE HOST (no scheme), e.g. 10.20.8.162 — the driver adds https:// itself; passing https://... makes it parse the scheme as the hostname and fail. Use the VMS management VIP (vms_ip), not the VoC node IP. Reachable from the cluster VPC (peered to the VAST VPC).", false),
		v("vmsUsername", "VAST VMS Username", "VMS user for CSI/COSI/block driver auth. Use a scoped manager account, not root admin.", true),
		v("vmsPassword", "VAST VMS Password", "Password for the VMS user above. Stored encrypted; written to the vast-mgmt Secret at deploy.", true),
		v("vastVipPool", "VAST VIP Pool", "Name of the VIP pool the data path uses (per-tenant). Place workers in the same AZ.", false),
		v("vastStoragePath", "VAST Storage Path", "Base view path on VAST where CSI volumes (views) are created, e.g. /k8s/tenant-a.", false),
		v("vastViewPolicy", "VAST View Policy", "VAST view policy controlling client access for CSI volumes (e.g. default).", false),
		v("vastQosPolicy", "VAST QoS Policy", "Optional VAST QoS policy applied to CSI StorageClasses (blank = none).", true),
		v("vastBlockSubsystem", "VAST Block Subsystem", "Name of the VAST view (protocols:[\"BLOCK\"]) used as the NVMe-TCP subsystem for the vast-block StorageClass; created by vast-tenancy terraform. Default k8s-block.", false),
	}
}

// buildPacks turns layer defs into pack manifest entities, resolving registry
// pack UIDs by name+tag and reading values/manifest YAML from disk.
func buildPacks(pc *client.V1Client, layers []packDef) ([]*models.V1PackManifestEntity, error) {
	out := make([]*models.V1PackManifestEntity, 0, len(layers))
	for _, d := range layers {
		manifests, err := buildManifests(d.manifests)
		if err != nil {
			return nil, fmt.Errorf("pack %q manifests: %w", d.name, err)
		}

		if d.manifestOnly {
			t := models.V1PackTypeManifest
			tag := "1.0.0"
			log.Printf("  layer %-18s type=manifest manifests=%d", d.name, len(manifests))
			out = append(out, &models.V1PackManifestEntity{
				Name:      apiutil.Ptr(d.name),
				UID:       fmt.Sprintf("%x", sha1.Sum([]byte("manifest-"+d.name)))[:24],
				Tag:       tag,
				Layer:     string(d.layer),
				Type:      &t,
				Manifests: manifests,
			})
			continue
		}

		uid, tag, defValues, err := resolvePack(pc, d.regUID, d.name, d.tagGlob)
		if err != nil {
			return nil, fmt.Errorf("resolve pack %q: %w", d.name, err)
		}
		// Use the override file if given; otherwise fall back to the pack's DEFAULT
		// values from the registry. Passing "" strips the pack's config (kubeadmconfig,
		// podCIDR, cloud-provider/CCM, CNI config, ...) — which leaves an AWS node stuck
		// cloud-provider-"uninitialized" with no CNI. The Palette UI auto-fills these;
		// the SDK does not, so we must.
		values, err := readFile(d.valuesFile)
		if err != nil {
			return nil, fmt.Errorf("pack %q values: %w", d.name, err)
		}
		if values == "" {
			values = defValues
		}
		t := models.V1PackTypeOci // must match the registry kind (ISC registry is type=oci)
		log.Printf("  layer %-18s tag=%-8s uid=%s values=%dB", d.name, tag, uid, len(values))
		out = append(out, &models.V1PackManifestEntity{
			Name:        apiutil.Ptr(d.name),
			UID:         uid,
			Tag:         tag,
			Layer:       string(d.layer),
			Type:        &t,
			RegistryUID: d.regUID,
			Values:      values,
			Manifests:   manifests,
		})
	}
	return out, nil
}

// resolvePack looks up a pack by name in a registry and returns the UID + tag of
// the requested version (tagGlob; "" or no match -> newest tag listed) plus the
// pack's DEFAULT values for that version (the values.yaml the UI pre-fills).
func resolvePack(pc *client.V1Client, regUID, name, tagGlob string) (uid, tag, defValues string, err error) {
	pt, err := pc.GetPacksByNameAndRegistry(name, regUID)
	if err != nil {
		return "", "", "", err
	}
	if pt == nil || len(pt.Tags) == 0 {
		return "", "", "", fmt.Errorf("no tags for pack %q in registry %s (did upload.sh push + Palette sync run?)", name, regUID)
	}
	// Prefer an exact/glob tag match; else fall back to the highest version.
	var best *models.V1PackTags
	for _, t := range pt.Tags {
		if tagGlob != "" && (t.Tag == tagGlob || matchGlob(t.Tag, tagGlob)) {
			best = t
			break
		}
		if best == nil || versionLess(best.Version, t.Version) {
			best = t
		}
	}
	if best == nil || best.PackUID == "" {
		return "", "", "", fmt.Errorf("pack %q: no usable tag/packUid", name)
	}
	// Default values for the chosen packUid (PackValues is keyed by packUid).
	for _, pv := range pt.PackValues {
		if pv.PackUID == best.PackUID {
			defValues = pv.Values
			break
		}
	}
	return best.PackUID, best.Tag, defValues, nil
}

// matchGlob handles simple "1.30.x" style globs against a concrete tag.
func matchGlob(tag, glob string) bool {
	if !strings.HasSuffix(glob, ".x") {
		return tag == glob
	}
	return strings.HasPrefix(tag, strings.TrimSuffix(glob, "x"))
}

// versionLess reports whether semver a < b (missing parts treated as 0).
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

func buildManifests(defs []manifestDef) ([]*models.V1ManifestInputEntity, error) {
	if len(defs) == 0 {
		return nil, nil
	}
	out := make([]*models.V1ManifestInputEntity, 0, len(defs))
	for _, m := range defs {
		content, err := readFile(m.file)
		if err != nil {
			return nil, fmt.Errorf("manifest %q: %w", m.name, err)
		}
		out = append(out, &models.V1ManifestInputEntity{Name: m.name, Content: content})
	}
	return out, nil
}

func readFile(path string) (string, error) {
	if path == "" {
		return "", nil
	}
	b, err := os.ReadFile(path)
	if err != nil {
		return "", err
	}
	return string(b), nil
}

// nextVersion returns the next patch version for profileName ("1.0.0" if none).
func nextVersion(pc *client.V1Client, name string) string {
	profiles, err := pc.GetClusterProfiles()
	if err != nil {
		log.Printf("warn: listing profiles (%v) — defaulting to 1.0.0", err)
		return "1.0.0"
	}
	maxPatch := -1
	for _, p := range profiles {
		if p.Metadata == nil || p.Metadata.Name != name || p.Spec == nil {
			continue
		}
		var maj, min, pat int
		if _, e := fmt.Sscanf(p.Spec.Version, "%d.%d.%d", &maj, &min, &pat); e == nil && pat > maxPatch {
			maxPatch = pat
		}
	}
	if maxPatch < 0 {
		return "1.0.0"
	}
	return fmt.Sprintf("1.0.%d", maxPatch+1)
}

// awsInfraLayers builds the OS/k8s/CNI/CSI stack for a full AWS cluster profile,
// resolved by name from the public registry. Names/tags are overridable via
// INFRA_<LAYER>_{NAME,TAG} env vars since they vary per Palette version.
func awsInfraLayers(pc *client.V1Client) []packDef {
	// SpectroCloud "Palette Registry" (ECR) holds the AWS infra packs on this
	// Palette instance. Overridable via PUBLIC_REGISTRY_UID / PUBLIC_REGISTRY name.
	pubUID := envOr("PUBLIC_REGISTRY_UID", "6a29d4836365d069f678a95a")
	if name := os.Getenv("PUBLIC_REGISTRY"); name != "" {
		if reg, err := pc.GetPackRegistryByName(name); err == nil && reg.Metadata != nil && reg.Metadata.UID != "" {
			pubUID = reg.Metadata.UID
		}
	}
	mk := func(layerEnv, defName, defTag, valuesFile string, layer models.V1PackLayer) packDef {
		return packDef{
			name:       envOr("INFRA_"+layerEnv+"_NAME", defName),
			tagGlob:    envOr("INFRA_"+layerEnv+"_TAG", defTag),
			layer:      layer,
			regUID:     pubUID,
			valuesFile: valuesFile,
		}
	}
	// Reproduces the working SaaS AWS infra profile (AI-RA-Infra-AWS): EXACT pack
	// versions + the CLOUD-CONFIGURED values (infra/*.yaml, extracted from the working
	// profile's export). The registry's raw DEFAULT values do NOT bootstrap — the OS
	// pack in particular must carry the node cloud-init + kubeadm cloud-provider/CCM
	// wiring, which the Palette UI injects but the SDK otherwise omits.
	// Attach the AWS cloud-controller-manager to the k8s layer. CAPA starts kubelet
	// with --cloud-provider=external, tainting every node
	// node.cloudprovider.kubernetes.io/uninitialized until a CCM clears it. Without
	// it the node never goes Ready, the CNI/agent never schedule, and provisioning
	// DEADLOCKS (node NotReady "cni plugin not initialized"). Attached to k8s so it
	// lands right after kubeadm, before the CNI. (vast-test-2651 had this; the
	// earlier SDK profile omitted it.)
	// Use the STANDARD registry packs with their DEFAULT (clean) values — the
	// documented AWS IaaS stack (Ubuntu OS + Kubernetes + Calico + AWS EBS CSI).
	// Passing "" => buildPacks falls back to the registry default values. We do NOT
	// override with local infra/*.yaml: the ubuntu-aws override was a BlueField-DPU +
	// MaaS bare-metal pack (BFB firmware download, MaaS-hosted nodeprep script,
	// nodeprep taint) — wrong for cloud AWS and the source of the nodeprep/MaaS hacks.
	// The clean defaults carry kubeadmconfig + preKubeadm; CAPA supplies the AWS
	// cloud-provider, and the aws-cloud-controller-manager (standard for AWS) clears
	// the cloud-provider "uninitialized" taint.
	// Use the WORKING infra values (proven by fieldeng-4/vast-test-2651), with the OS
	// pack now CLEANED of the MaaS/nodeprep (infra/ubuntu-aws.yaml = the 8539B working
	// config minus the MaaS-hosted nodeprep + nodeprep taint). NOT the bare registry
	// default — that 1936B "default" is just commented-out examples (no kubeadmconfig),
	// which left nodes with zero bootstrap config and broke them.
	k8s := mk("K8S", "kubernetes", "1.34.5", "infra/kubernetes.yaml", models.V1PackLayerK8s)
	k8s.manifests = append(k8s.manifests, manifestDef{name: "aws-cloud-controller-manager", file: "infra/aws-ccm.yaml"})
	return []packDef{
		mk("OS", "ubuntu-aws", "24.04", "infra/ubuntu-aws.yaml", models.V1PackLayerOs),
		k8s,
		mk("CNI", "cni-calico", "3.31.5", "infra/cni-calico.yaml", models.V1PackLayerCni),
		mk("CSI", "csi-aws-ebs", "1.60.0", "infra/csi-aws-ebs.yaml", models.V1PackLayerCsi),
	}
}
