package workflow_test

import (
	"os"
	"path/filepath"
	"strings"
	"testing"

	"gopkg.in/yaml.v3"
)

func TestMacOSPublicationRequiresSignedNotarizedArtifacts(t *testing.T) {
	data, err := os.ReadFile(filepath.Join("..", "..", ".github", "workflows", "macos-release.yml"))
	if err != nil {
		t.Fatal(err)
	}
	var definition struct {
		Jobs map[string]struct {
			Needs       []string       `yaml:"needs"`
			Environment string         `yaml:"environment"`
			Steps       []workflowStep `yaml:"steps"`
		} `yaml:"jobs"`
	}
	if err := yaml.Unmarshal(data, &definition); err != nil {
		t.Fatal(err)
	}
	macos := definition.Jobs["macos"]
	if macos.Environment != "macos-release" {
		t.Fatal("signing must run in the macos-release environment")
	}
	sign := requireStep(t, macos.Steps, "Sign, notarize and staple disk image")
	e2e := requireStep(t, macos.Steps, "Require current Cursor compatibility before signing")
	if e2e >= sign {
		t.Fatal("current Cursor acceptance must precede signing")
	}
	upload := requireStep(t, macos.Steps, "Upload notarized artifacts")
	if sign >= upload || !strings.Contains(macos.Steps[sign].Run, "scripts/sign-macos.sh") {
		t.Fatal("artifact upload must follow successful signing and notarization")
	}
	if needs := definition.Jobs["publish"].Needs; len(needs) != 2 || needs[0] != "verify" || needs[1] != "macos" {
		t.Fatal("publication must depend on verification and both macOS signing jobs")
	}
	publish := definition.Jobs["publish"].Steps
	checksums := requireStep(t, publish, "Verify final artifact checksums")
	release := requireStep(t, publish, "Publish fork release")
	if checksums >= release {
		t.Fatal("final artifact checksums must be verified before publication")
	}
}
