package plan

import (
	"strings"
	"testing"
)

func TestRepositoryPrecedence(t *testing.T) {
	for _, old := range []string{"", BootstrapRepository, PublishedRepository + BootstrapRepository} {
		for _, position := range []string{"before", "after"} {
			s := "[options]\nSigLevel = Required DatabaseOptional\n"
			if position == "before" {
				s += old
			}
			s += "[core]\nInclude = /etc/pacman.d/mirrorlist\n[extra]\nInclude = /etc/pacman.d/mirrorlist\n"
			if position == "after" {
				s += old
			}
			s += "#[multilib]\n#Include = /etc/pacman.d/mirrorlist\n"
			bootstrap := Repository(Multilib(s), BootstrapRepository)
			if strings.Count(bootstrap, "[gilgamesh]") != 1 || strings.Index(bootstrap, "[gilgamesh]") > strings.Index(bootstrap, "[core]") || !strings.Contains(bootstrap, "SigLevel = Required DatabaseOptional") || !strings.Contains(bootstrap, "[multilib]\nInclude") {
				t.Fatal(bootstrap)
			}
			clean := TargetPacman(bootstrap)
			if strings.Contains(clean, "gilgamesh") || strings.Contains(clean, "Never") || !strings.Contains(clean, "[core]\nInclude") || !strings.Contains(clean, "[extra]\nInclude") {
				t.Fatal(clean)
			}
			published := Repository(clean, PublishedRepository)
			if strings.Count(published, "[gilgamesh]") != 1 || strings.Index(published, "[gilgamesh]") > strings.Index(published, "[core]") || !strings.Contains(published, PublishedRepository[:len(PublishedRepository)-1]) {
				t.Fatal(published)
			}
		}
	}
}

func TestTargetPacmanSanitizesUnsignedPolicy(t *testing.T) {
	s := "[options]\nSigLevel = Never # bootstrap\n [gilgamesh] # old\nSigLevel = Never\nServer = file:///opt/gilgamesh/repo\n[core]\nSigLevel = PackageNever DatabaseNever\nInclude = mirrorlist\n[gilgamesh]\nServer = file:///old\n[extra]\nSigLevel = Required DatabaseOptional\nInclude = mirrorlist\n"
	got := TargetPacman(s)
	for _, bad := range []string{"Never", "gilgamesh", "file:///"} {
		if strings.Contains(got, bad) {
			t.Fatal(got)
		}
	}
	if strings.Count(got, "SigLevel = Required DatabaseRequired") != 2 || !strings.Contains(got, "[extra]\nSigLevel = Required DatabaseOptional\nInclude = mirrorlist") {
		t.Fatal(got)
	}
}
