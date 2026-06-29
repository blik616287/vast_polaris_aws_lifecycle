package main

import (
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
)

// runRelease is the publish half of the iterative workflow, gated on a green
// test run: it bumps each validated pack to a new version, pushes the artifacts
// to ECR + syncs the Palette registry (via upload.sh), then republishes the
// add-on cluster profile pointing at the new version (via create-profile).
//
// It shells out to the existing, working tools rather than reimplementing oras /
// the Palette SDK — packtest is the orchestrator that ties test → ship together.
//
// Needs PALETTE_APIKEY (or PALETTE_API_KEY) in the env; AWS profile `spectro`
// for the ECR push (upload.sh default). PALETTE_PROJECT scopes create-profile.
func runRelease(selected []pack, version string) error {
	token := firstNonEmpty(os.Getenv("PALETTE_APIKEY"), os.Getenv("PALETTE_API_KEY"))
	if token == "" {
		return fmt.Errorf("PALETTE_APIKEY (or PALETTE_API_KEY) is required for -release")
	}
	// Absolute paths: upload.sh / create-profile run with their own Cmd.Dir, so a
	// relative path would resolve against the wrong base.
	absCharts, err := filepath.Abs(*chartsDir)
	if err != nil {
		return err
	}
	root := filepath.Dir(absCharts) // parent of testpacks/ == pack_devel/

	// 1) bump each pack: copy testpacks/<name>-<oldver> -> <name>-<version>, edit pack.json.
	var dirs []string
	for _, p := range selected {
		src := filepath.Join(absCharts, fmt.Sprintf("%s-%s", p.name, *ver))
		dst := filepath.Join(absCharts, fmt.Sprintf("%s-%s", p.name, version))
		if err := run("rm", "-rf", dst); err != nil {
			return err
		}
		if err := run("cp", "-r", src, dst); err != nil {
			return fmt.Errorf("bump copy %s: %w", p.name, err)
		}
		if err := bumpPackJSON(filepath.Join(dst, "pack.json"), version); err != nil {
			return fmt.Errorf("bump pack.json %s: %w", p.name, err)
		}
		dirs = append(dirs, dst)
		fmt.Printf("  bumped %s %s -> %s\n", p.name, *ver, version)
	}

	// 2) push to ECR + sync the Palette registry.
	fmt.Println("\n==> push to ECR + sync Palette (upload.sh)")
	up := exec.Command("bash", append([]string{filepath.Join(root, "upload.sh")}, dirs...)...)
	up.Dir = root
	up.Env = append(os.Environ(), "PALETTE_APIKEY="+token)
	up.Stdout, up.Stderr = os.Stdout, os.Stderr
	if err := up.Run(); err != nil {
		return fmt.Errorf("upload.sh (push/sync) failed: %w — if only the sync timed out, the ECR push likely succeeded; sync the registry in the Palette UI and re-run with -release-skip-push", err)
	}

	// 3) republish the add-on cluster profile pointing at the new pack version.
	fmt.Println("\n==> update cluster profile (create-profile, VAST_PACK_TAG=" + version + ")")
	cp := exec.Command("go", "run", "./cmd/create-profile")
	cp.Dir = filepath.Join(root, "vast-profile")
	cp.Env = append(os.Environ(),
		"PALETTE_API_KEY="+token,
		"VAST_PACK_TAG="+version,
		"PROFILE_TYPE="+firstNonEmpty(os.Getenv("PROFILE_TYPE"), "add-on"),
		"PROFILE_NAME="+firstNonEmpty(os.Getenv("PROFILE_NAME"), "vast-storage"),
	)
	cp.Stdout, cp.Stderr = os.Stdout, os.Stderr
	if err := cp.Run(); err != nil {
		return fmt.Errorf("create-profile failed: %w", err)
	}
	fmt.Printf("\n==> released %d pack(s) at %s and updated the cluster profile\n", len(dirs), version)
	return nil
}

var versionRe = regexp.MustCompile(`"version"\s*:\s*"[^"]*"`)

// bumpPackJSON rewrites pack.json's "version" field in place.
func bumpPackJSON(path, version string) error {
	b, err := os.ReadFile(path)
	if err != nil {
		return err
	}
	out := versionRe.ReplaceAll(b, []byte(fmt.Sprintf(`"version": %q`, version)))
	return os.WriteFile(path, out, 0o644)
}

func firstNonEmpty(vs ...string) string {
	for _, v := range vs {
		if v != "" {
			return v
		}
	}
	return ""
}
