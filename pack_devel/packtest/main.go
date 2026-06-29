// packtest spins up a local kind cluster and validates the VAST Data Palette
// packs (vast-csi / vast-cosi / vast-block) the way Palette would render them —
// WITHOUT a 20-minute cloud deploy. It catches the whole class of bugs we hit
// in the cloud (Helm template fails, missing CRDs, list-vs-string value types,
// bad endpoints) in ~60s, before anything is published to ECR.
//
// What it does, per pack:
//  1. ensure a kind cluster exists (creates one if absent),
//  2. install the prerequisite CRDs the charts reference
//     (VolumeSnapshotClass for CSI, BucketClass for COSI),
//  3. create the pack namespace + the `vast-mgmt` credentials secret,
//  4. extract the chart values from the pack's values.yaml (the `charts.<name>`
//     subtree), substitute the {{.spectro.var.*}} macros with test inputs,
//  5. `helm template` (render gate) then `helm install` (install gate),
//  6. best-effort check that the workload pods schedule (build-on-deploy).
//
// It then prints a pass/fail matrix and (unless -keep) tears the cluster down.
//
// Usage:
//
//	go run .                 # test all three packs end to end
//	go run . -keep           # leave the cluster up for inspection
//	go run . -packs vast-cosi
//	go run . -pods           # also wait for pods to schedule (slower)
//
// Requires: docker, kind, helm, kubectl on PATH.
package main

import (
	"embed"
	"encoding/json"
	"flag"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"sort"
	"strings"
	"time"

	"gopkg.in/yaml.v3"
)

//go:embed crds/*.yaml
var crdFS embed.FS

// pack describes one VAST pack under test: where its pack-level values.yaml and
// chart tarball live, the Helm chart's release/subtree name, and how the shared
// {{.spectro.var.vmsEndpoint}} macro should resolve for THIS chart — CSI/block
// read the endpoint from the vast-mgmt secret (so empty is correct), while the
// COSI chart requires a bare host in the value itself.
type pack struct {
	name      string // pack dir/name, e.g. "vast-csi"
	chart     string // chart + values subtree name, e.g. "vastcsi"
	vmsInline string // value substituted for {{.spectro.var.vmsEndpoint}}
}

var packs = []pack{
	{name: "vast-csi", chart: "vastcsi", vmsInline: ""},
	{name: "vast-cosi", chart: "vastcosi", vmsInline: "__VMS__"}, // replaced with -vms (bare host)
	{name: "vast-block", chart: "vastblock", vmsInline: ""},
}

var (
	clusterName = flag.String("cluster", "vast-test", "kind cluster name")
	keep        = flag.Bool("keep", false, "keep the kind cluster after the run")
	packsFlag   = flag.String("packs", "", "comma-separated packs to test (default: all)")
	packsDir    = flag.String("packs-dir", "../vast-profile/packs", "dir holding <pack>-values.yaml")
	chartsDir   = flag.String("charts-dir", "../testpacks", "dir holding <pack>-<ver>/charts/<chart>-<ver>.tgz")
	ver         = flag.String("ver", "2.6.5", "pack/chart version")
	vms         = flag.String("vms", "10.20.13.207", "VMS host for the COSI endpoint / vast-mgmt secret")
	checkPods   = flag.Bool("pods", false, "also run the build-on-deploy gate (slower)")
	jsonOut     = flag.Bool("json", false, "emit the report as JSON (machine/LLM consumable)")
	release     = flag.String("release", "", "after gates pass: bump packs to this version, push to ECR, sync Palette, update the profile")
	kindImage   = flag.String("kind-image", "", "optional kindest/node image override")
	skipBlockPrereq = flag.Bool("skip-block-prereq", false, "do NOT load nvme-tcp + install nvme-cli into the kind node for vast-block (reproduces the driver-load failure the profile's preKubeadm step fixes)")
)

// testVars are the per-cluster inputs Palette would fill from profile variables.
func testVars(vmsInline string) map[string]string {
	return map[string]string{
		"{{.spectro.var.vmsEndpoint}}":     vmsInline,
		"{{.spectro.var.vmsUsername}}":     "admin",
		"{{.spectro.var.vmsPassword}}":     "123456",
		"{{.spectro.var.vastVipPool}}":     "vippool-1",
		"{{.spectro.var.vastStoragePath}}": "/csi",
		"{{.spectro.var.vastViewPolicy}}":  "default",
		"{{.spectro.var.vastQosPolicy}}":   "",
	}
}

// result is the outcome for one pack. Tagged for -json so a downstream consumer
// (CI, or an LLM doing troubleshooting / continued development) gets structured,
// actionable output rather than a log to re-parse.
type result struct {
	Pack          string     `json:"pack"`
	Render        string     `json:"render"`        // ok / FAIL
	Install       string     `json:"install"`       // ok / FAIL / -
	BuildOnDeploy string     `json:"buildOnDeploy"` // ok / pending / FAIL / -
	Detail        string     `json:"detail,omitempty"`
	BODErrors     []bodError `json:"buildOnDeployErrors,omitempty"`
}

// bodError is one captured build-on-deploy runtime failure, classified with the
// evidence and a concrete fix hint — the actionable unit an LLM consumer reads.
type bodError struct {
	Pod       string   `json:"pod"`
	Container string   `json:"container"`
	Class     string   `json:"class"`     // e.g. glibc-version-mismatch
	Signature string   `json:"signature"` // the matched marker
	Evidence  []string `json:"evidence"`  // the actual log lines
	Hint      string   `json:"hint"`      // how to fix it
}

// bodClass maps a log signature to a stable error class + a fix hint. Order
// matters: more specific signatures first.
var bodClasses = []struct {
	sig, class, hint string
}{
	// vast-block node prereqs (NOT build-on-deploy — node/OS requirements the
	// profile's preKubeadm step provides). Listed first so the driver-load crash is
	// classified distinctly instead of falling through to the generic missing-binary.
	{"Module nvme-tcp not found", "block-node-prereq",
		"vast-block needs the nvme-tcp kernel module on the node — absent from the base Ubuntu AWS image (ships in linux-modules-extra-<kver>). Add a preKubeadm step: apt-get install -y linux-modules-extra-$(uname -r) && modprobe nvme-tcp. (packtest loads it on the host kernel; pass -skip-block-prereq to reproduce.)"},
	{"try_nvme_probes", "block-node-prereq",
		"vast-block's driver shells the nvme CLI (nvme version/discover/connect) on the host; nvme-cli is absent from the base Ubuntu AWS image. Add a preKubeadm step: apt-get install -y nvme-cli. (packtest installs it into the kind node; pass -skip-block-prereq to reproduce.)"},
	{"GLIBC_", "glibc-version-mismatch",
		"The craned image's glibc is older than wolfi-base's coreutils need; launch.sh exports LD_LIBRARY_PATH to the craned libs, which then breaks wolfi-base tools (head/basename) and the entrypoint parse. Fix: invoke the craned binary via its own ld-linux loader with --library-path, and parse the OCI entrypoint BEFORE touching the library path."},
	{"not found (required by", "glibc-version-mismatch",
		"A wolfi-base tool was run against the craned image's older libc. Don't export LD_LIBRARY_PATH globally; scope the craned libs to the craned binary only (its own ld-linux --library-path)."},
	{"loading shared libraries", "missing-shared-library",
		"A required .so isn't resolvable for the craned binary. Ensure the craned rootfs is complete and the loader's --library-path includes its lib dirs (usr/lib64, lib64, usr/lib)."},
	{"cannot open shared object", "missing-shared-library",
		"Shared object missing on the craned rootfs / library path. Verify crane export extracted all layers."},
	{"exec format error", "exec-format",
		"Wrong-arch or corrupt craned binary (often a multi-arch image craned for the wrong platform). Pin crane to the node architecture (linux/amd64)."},
	{"cannot execute binary", "exec-format",
		"Craned binary is not executable on this arch. Pin the crane platform and confirm the binary path."},
	{"launch.sh: exec", "bad-exec-target",
		"launch.sh produced an empty/invalid exec target — usually because entrypoint parsing failed under a broken ld swap. Parse the OCI Entrypoint/Cmd before altering the library path."},
	{": Permission denied", "bad-exec-target",
		"exec hit a non-executable or empty target. Check the resolved binary path and that it is +x in the craned rootfs."},
	{"No such file or directory", "missing-binary",
		"The expected binary isn't in the craned rootfs at the resolved path. Check OCI Entrypoint/Cmd resolution and the /runtime/<key> layout."},
}

func main() {
	flag.Parse()
	selected := selectPacks(*packsFlag)
	if len(selected) == 0 {
		fmt.Fprintln(os.Stderr, "no packs selected")
		os.Exit(2)
	}
	for _, t := range []string{"docker", "kind", "helm", "kubectl"} {
		if _, err := exec.LookPath(t); err != nil {
			fatalf("required tool %q not found on PATH", t)
		}
	}

	if err := ensureKind(); err != nil {
		fatalf("kind cluster: %v", err)
	}
	if !*keep {
		defer func() {
			fmt.Println("\n==> tearing down kind cluster (use -keep to retain)")
			_ = run("kind", "delete", "cluster", "--name", *clusterName)
		}()
	}

	if err := installCRDs(); err != nil {
		fatalf("installing prerequisite CRDs: %v", err)
	}

	var results []result
	for _, p := range selected {
		results = append(results, testPack(p))
	}
	printReport(results)
	failed := false
	for _, r := range results {
		if r.Render == "FAIL" || r.Install == "FAIL" || r.BuildOnDeploy == "FAIL" {
			failed = true
		}
	}
	if failed {
		if *release != "" {
			fmt.Fprintln(os.Stderr, "\npacktest: NOT releasing — one or more gates failed")
		}
		os.Exit(1)
	}
	// Publish half of the iterative workflow — only on a fully green run.
	if *release != "" {
		if !*checkPods {
			fmt.Fprintln(os.Stderr, "packtest: refusing to release without the build-on-deploy gate; re-run with -pods")
			os.Exit(2)
		}
		if err := runRelease(selectPacks(*packsFlag), *release); err != nil {
			fatalf("release: %v", err)
		}
	}
}

func selectPacks(csv string) []pack {
	if strings.TrimSpace(csv) == "" {
		return packs
	}
	want := map[string]bool{}
	for _, s := range strings.Split(csv, ",") {
		want[strings.TrimSpace(s)] = true
	}
	var out []pack
	for _, p := range packs {
		if want[p.name] {
			out = append(out, p)
		}
	}
	return out
}

// ensureKind creates the kind cluster if it isn't already running.
func ensureKind() error {
	out, _ := runOut("kind", "get", "clusters")
	for _, l := range strings.Split(out, "\n") {
		if strings.TrimSpace(l) == *clusterName {
			fmt.Printf("==> reusing kind cluster %q\n", *clusterName)
			return useContext()
		}
	}
	fmt.Printf("==> creating kind cluster %q\n", *clusterName)
	args := []string{"create", "cluster", "--name", *clusterName, "--wait", "120s"}
	if *kindImage != "" {
		args = append(args, "--image", *kindImage)
	}
	if err := run("kind", args...); err != nil {
		return err
	}
	return useContext()
}

func useContext() error { return run("kubectl", "config", "use-context", "kind-"+*clusterName) }

// blockNodePrereq mirrors the cluster profile's preKubeadm step so packtest exercises
// the REAL vast-block deployment, not a half-installed one. The block driver needs two
// node-level things the base node image lacks: the nvme-tcp kernel module and the
// nvme-cli userspace tool. kind nodes share the host kernel, so we modprobe nvme-tcp on
// the host (visible inside the kind node), and install nvme-cli into the kind node
// container (the driver shells `nvme ...` against the node's /host). -skip-block-prereq
// leaves both out, reproducing the CrashLoopBackOff the gate now catches.
func blockNodePrereq() {
	if *skipBlockPrereq {
		fmt.Println("   -skip-block-prereq: NOT loading nvme-tcp / nvme-cli (block driver-load will fail)")
		return
	}
	fmt.Println("   node prereq: nvme-tcp module + nvme-cli (mirrors profile preKubeadm)")
	if err := run("sudo", "modprobe", "nvme-tcp"); err != nil {
		fmt.Printf("   warn: 'sudo modprobe nvme-tcp' failed (%v) — host kernel may lack it; block node may not load\n", err)
	}
	node := *clusterName + "-control-plane"
	if _, err := runOut("docker", "exec", node, "sh", "-c",
		"command -v nvme >/dev/null 2>&1 || { apt-get update -y >/dev/null 2>&1 && DEBIAN_FRONTEND=noninteractive apt-get install -y nvme-cli >/dev/null 2>&1; }"); err != nil {
		fmt.Printf("   warn: installing nvme-cli into kind node failed: %v\n", err)
	}
}

// installCRDs applies every embedded CRD (sorted, so ordering is deterministic).
func installCRDs() error {
	fmt.Println("==> installing prerequisite CRDs")
	entries, err := crdFS.ReadDir("crds")
	if err != nil {
		return err
	}
	var files []string
	for _, e := range entries {
		if !e.IsDir() && strings.HasSuffix(e.Name(), ".yaml") {
			files = append(files, e.Name())
		}
	}
	sort.Strings(files)
	for _, f := range files {
		b, err := crdFS.ReadFile("crds/" + f)
		if err != nil {
			return err
		}
		if err := runStdin(b, "kubectl", "apply", "-f", "-"); err != nil {
			return fmt.Errorf("apply %s: %w", f, err)
		}
	}
	return nil
}

// testPack runs the render → install → pods gates for one pack.
func testPack(p pack) result {
	r := result{Pack: p.name, Render: "-", Install: "-", BuildOnDeploy: "-"}
	fmt.Printf("\n==> %s\n", p.name)

	// vast-block has node-level prereqs (nvme-tcp module + nvme-cli) the profile's
	// preKubeadm provides; apply the same to the kind node before the driver starts.
	if p.name == "vast-block" && *checkPods {
		blockNodePrereq()
	}

	// 1) namespace + vast-mgmt secret (idempotent; quiet on already-exists).
	_, _ = runOut("kubectl", "create", "namespace", p.name)
	_, _ = runOut("kubectl", "-n", p.name, "delete", "secret", "vast-mgmt", "--ignore-not-found")
	if err := run("kubectl", "-n", p.name, "create", "secret", "generic", "vast-mgmt",
		"--from-literal=username=admin", "--from-literal=password=123456",
		"--from-literal=endpoint=https://"+*vms); err != nil {
		r.Detail = "secret: " + err.Error()
		return r
	}

	// 2) extract chart values + substitute macros.
	valsFile, err := chartValues(p)
	if err != nil {
		r.Render, r.Detail = "FAIL", err.Error()
		return r
	}
	tgz := filepath.Join(*chartsDir, fmt.Sprintf("%s-%s", p.name, *ver), "charts", fmt.Sprintf("%s-%s.tgz", p.chart, *ver))

	// 3) render gate (helm template).
	if out, err := runOut("helm", "template", p.chart, tgz, "-n", p.name, "-f", valsFile); err != nil {
		r.Render, r.Detail = "FAIL", firstError(out+err.Error())
		return r
	}
	r.Render = "ok"

	// 4) install gate (helm install); drop any stale release first, quietly.
	_, _ = runOut("helm", "uninstall", p.chart, "-n", p.name)
	if out, err := runOut("helm", "install", p.chart, tgz, "-n", p.name, "-f", valsFile, "--timeout", "90s"); err != nil {
		r.Install, r.Detail = "FAIL", firstError(out+err.Error())
		return r
	}
	r.Install = "ok"

	// 5) build-on-deploy gate: craned binaries must actually execute.
	if *checkPods {
		r.BuildOnDeploy, r.Detail, r.BODErrors = waitPods(p.name)
	}
	return r
}

// chartValues writes a temp values file containing the `charts.<chart>` subtree
// of the pack's values.yaml with the test macros substituted.
func chartValues(p pack) (string, error) {
	raw, err := os.ReadFile(filepath.Join(*packsDir, p.name+"-values.yaml"))
	if err != nil {
		return "", err
	}
	var top map[string]any
	if err := yaml.Unmarshal(raw, &top); err != nil {
		return "", fmt.Errorf("parse values.yaml: %w", err)
	}
	charts, _ := top["charts"].(map[string]any)
	sub, ok := charts[p.chart].(map[string]any)
	if !ok {
		return "", fmt.Errorf("no charts.%s in %s-values.yaml", p.chart, p.name)
	}
	out, err := yaml.Marshal(sub)
	if err != nil {
		return "", err
	}
	s := string(out)
	inline := p.vmsInline
	if inline == "__VMS__" {
		inline = *vms // COSI needs a bare host
	}
	for k, v := range testVars(inline) {
		s = strings.ReplaceAll(s, k, v)
	}
	f := filepath.Join(os.TempDir(), fmt.Sprintf("packtest-%s.yaml", p.chart))
	if err := os.WriteFile(f, []byte(s), 0o644); err != nil {
		return "", err
	}
	return f, nil
}

// podList is the slice of the kubectl JSON we care about.
type podList struct {
	Items []struct {
		Metadata struct{ Name string } `json:"metadata"`
		Status   struct {
			InitContainerStatuses []containerStatus `json:"initContainerStatuses"`
			ContainerStatuses     []containerStatus `json:"containerStatuses"`
		} `json:"status"`
	} `json:"items"`
}

type containerStatus struct {
	Name         string `json:"name"`
	RestartCount int    `json:"restartCount"`
	State        struct {
		Terminated *struct {
			ExitCode int    `json:"exitCode"`
			Reason   string `json:"reason"`
		} `json:"terminated"`
		Waiting *struct {
			Reason string `json:"reason"`
		} `json:"waiting"`
		Running *struct{} `json:"running"`
	} `json:"state"`
}

// vmsSignatures mark the EXPECTED local failure: the binary ran fine but can't
// reach a real VMS. Seeing only these means build-on-deploy itself worked.
var vmsSignatures = []string{
	"connection refused", "dial tcp", "i/o timeout", "context deadline",
	"no route to host", "x509", "Unauthorized", "401", "EOF", "Temporary failure in name resolution",
}

// classify returns the build-on-deploy error class + hint for a log line, or
// ("","") if the line isn't a build-on-deploy failure.
func classify(line string) (class, hint, sig string) {
	for _, b := range bodClasses {
		if strings.Contains(line, b.sig) {
			return b.class, b.hint, b.sig
		}
	}
	return "", "", ""
}

func isVMS(line string) bool {
	for _, s := range vmsSignatures {
		if strings.Contains(line, s) {
			return true
		}
	}
	return false
}

// waitPods validates build-on-deploy WITHOUT a VMS in two stages:
//  1. the `fetch-runtime` init container must crane every image onto wolfi-base
//     and exit 0 (prep stage), and
//  2. the craned binaries must actually EXECUTE — we read the workload
//     containers' logs and FAIL on a build-on-deploy signature (bad ld swap,
//     exec format, Permission denied), while tolerating the driver crash-looping
//     purely because the test VMS is unreachable.
//
// Stage 2 is the part that catches matched-ld-swap regressions; stage 1 alone
// gives false passes (the init can succeed while the binary it prepared can't run).
func waitPods(ns string) (string, string, []bodError) {
	deadline := time.Now().Add(5 * time.Minute) // crane pulls upstream images fresh each install
	cleanStreak := 0                            // require 2 consecutive clean polls so a startup crash has time to surface
	for time.Now().Before(deadline) {
		out, _ := runOut("kubectl", "-n", ns, "get", "pods", "-o", "json")
		var pl podList
		if json.Unmarshal([]byte(out), &pl) != nil || len(pl.Items) == 0 {
			time.Sleep(5 * time.Second)
			continue
		}
		// Stage 1: init (crane prep) must complete.
		var done, total int
		settled := true
		for _, p := range pl.Items {
			for _, c := range p.Status.InitContainerStatuses {
				total++
				switch {
				case c.State.Terminated != nil && c.State.Terminated.ExitCode == 0:
					done++
				case c.State.Terminated != nil:
					return "FAIL", fmt.Sprintf("init %s exit %d (build-on-deploy prep failed)", c.Name, c.State.Terminated.ExitCode), nil
				case c.State.Waiting != nil && c.State.Waiting.Reason == "ImagePullBackOff":
					return "FAIL", fmt.Sprintf("init %s ImagePullBackOff (cannot pull build-on-deploy base)", c.Name), nil
				default:
					settled = false
				}
			}
		}
		if total == 0 || done < total || !settled {
			time.Sleep(8 * time.Second)
			continue
		}
		// Stage 1b: workload containers must have had a chance to start before we
		// judge — otherwise we can scan in the window AFTER init but BEFORE the
		// driver's startup probe runs and crashes, and falsely pass (this is exactly
		// how the vast-block nvme driver-load failure slipped through). A workload
		// container is "settled" once it is Running, has crashed at least once
		// (RestartCount>0), or has terminated; still-starting (Waiting, never
		// restarted) means wait.
		wlSettled := true
		for _, p := range pl.Items {
			for _, c := range p.Status.ContainerStatuses {
				if c.State.Running == nil && c.State.Terminated == nil && c.RestartCount == 0 {
					wlSettled = false
				}
			}
		}
		if !wlSettled {
			time.Sleep(8 * time.Second)
			continue
		}
		// Stage 2: the craned binaries must actually run. Capture EVERY
		// build-on-deploy error across all containers (classified, with evidence).
		errs := scanBuildOnDeploy(ns, pl)
		if len(errs) > 0 {
			return "FAIL", fmt.Sprintf("%d build-on-deploy/node-prereq runtime error(s); see buildOnDeployErrors", len(errs)), errs
		}
		// A single clean scan isn't enough: a workload container can be caught in its
		// brief transient-Running window before its startup probe crashes it (the
		// vast-block nvme case). Require two consecutive clean polls — by the second,
		// a crash has incremented RestartCount and scanBuildOnDeploy reads its logs.
		cleanStreak++
		if cleanStreak < 2 {
			time.Sleep(8 * time.Second)
			continue
		}
		return "ok", fmt.Sprintf("build-on-deploy %d/%d init + craned binaries exec OK; driver needs real VMS", done, total), nil
	}
	return "pending", "build-on-deploy still initializing", nil
}

// scanBuildOnDeploy reads every non-running workload container's logs (current +
// previous) and returns ALL classified build-on-deploy failures, each with the
// matching log lines as evidence. VMS-connectivity-only crashes are ignored
// (expected without a VMS). Deduped by (container, class).
func scanBuildOnDeploy(ns string, pl podList) []bodError {
	var errs []bodError
	seen := map[string]bool{}
	for _, p := range pl.Items {
		for _, c := range p.Status.ContainerStatuses {
			if c.State.Running != nil && c.RestartCount == 0 { // cleanly running, never crashed -> execs fine
				continue
			}
			logs, _ := runOut("kubectl", "-n", ns, "logs", p.Metadata.Name, "-c", c.Name, "--tail", "60")
			if prev, err := runOut("kubectl", "-n", ns, "logs", p.Metadata.Name, "-c", c.Name, "--tail", "60", "--previous"); err == nil {
				logs += "\n" + prev
			}
			byClass := map[string]*bodError{}
			var order []string
			for _, line := range strings.Split(logs, "\n") {
				line = strings.TrimSpace(line)
				if line == "" || isVMS(line) {
					continue
				}
				class, hint, sig := classify(line)
				if class == "" {
					continue
				}
				key := c.Name + "|" + class
				if seen[key] {
					if be := byClass[class]; be != nil && len(be.Evidence) < 4 {
						be.Evidence = append(be.Evidence, truncate(line, 200))
					}
					continue
				}
				if byClass[class] == nil {
					byClass[class] = &bodError{Pod: p.Metadata.Name, Container: c.Name, Class: class, Signature: sig, Hint: hint}
					order = append(order, class)
				}
				if len(byClass[class].Evidence) < 4 {
					byClass[class].Evidence = append(byClass[class].Evidence, truncate(line, 200))
				}
			}
			for _, class := range order {
				seen[c.Name+"|"+class] = true
				errs = append(errs, *byClass[class])
			}
		}
	}
	return errs
}

// ---- helpers --------------------------------------------------------------

func printReport(rs []result) {
	if *jsonOut {
		b, _ := json.MarshalIndent(struct {
			Packs []result `json:"packs"`
		}{rs}, "", "  ")
		fmt.Println(string(b))
		return
	}
	fmt.Printf("\n%-12s %-8s %-8s %-9s %s\n", "PACK", "RENDER", "INSTALL", "BUILD-ON-DEPLOY", "DETAIL")
	fmt.Println(strings.Repeat("-", 78))
	for _, r := range rs {
		fmt.Printf("%-12s %-8s %-8s %-9s %s\n", r.Pack, r.Render, r.Install, r.BuildOnDeploy, r.Detail)
	}
	// Expand captured build-on-deploy errors — actionable detail for troubleshooting.
	for _, r := range rs {
		for _, e := range r.BODErrors {
			fmt.Printf("\n  ✗ %s [%s] %s/%s\n", r.Pack, e.Class, e.Pod, e.Container)
			for _, ev := range e.Evidence {
				fmt.Printf("      | %s\n", ev)
			}
			fmt.Printf("      → %s\n", e.Hint)
		}
	}
}

// firstError pulls the most useful line out of a Helm/kubectl error blob.
func firstError(s string) string {
	for _, l := range strings.Split(s, "\n") {
		l = strings.TrimSpace(l)
		if strings.Contains(l, "Error:") || strings.Contains(l, "execution error") || strings.Contains(l, "failed") {
			return truncate(l, 180)
		}
	}
	return truncate(strings.TrimSpace(s), 180)
}

func truncate(s string, n int) string {
	if len(s) > n {
		return s[:n] + "…"
	}
	return s
}

func run(name string, args ...string) error {
	cmd := exec.Command(name, args...)
	cmd.Stdout, cmd.Stderr = os.Stdout, os.Stderr
	return cmd.Run()
}

func runOut(name string, args ...string) (string, error) {
	out, err := exec.Command(name, args...).CombinedOutput()
	return string(out), err
}

func runStdin(stdin []byte, name string, args ...string) error {
	cmd := exec.Command(name, args...)
	cmd.Stdin = strings.NewReader(string(stdin))
	cmd.Stdout, cmd.Stderr = os.Stdout, os.Stderr
	return cmd.Run()
}

func fatalf(format string, a ...any) {
	fmt.Fprintf(os.Stderr, "packtest: "+format+"\n", a...)
	os.Exit(1)
}
