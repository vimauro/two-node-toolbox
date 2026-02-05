package main

import (
	"flag"
	"fmt"
	"os"
	"path/filepath"
	"strings"

	"github.com/kevinburke/ssh_config"
)

var (
	hostName     string
	identityFile string
	user         string
	key          string
)

func main() {
	sshConfigPath := filepath.Join(os.Getenv("HOME"), ".ssh", "config")
	flag.StringVar(&key, "k", "", "host key to update")
	flag.StringVar(&hostName, "h", "", "hostname")
	flag.StringVar(&identityFile, "i", "", "identity file path")
	flag.StringVar(&user, "u", "", "user")
	flag.Parse()

	f, err := os.Open(sshConfigPath)
	if err != nil {
		if os.IsNotExist(err) {
			fmt.Fprintln(os.Stderr, "ssh config file not found, skipping update")
			os.Exit(0)
		} else {
			panic(err)
		}
	}

	defer f.Close()

	cfg, err := ssh_config.Decode(f)
	if err != nil {
		panic(err)
	}

	matched := false
	for _, host := range cfg.Hosts {

		isWildcardOnly := len(host.Patterns) == 1 && host.Patterns[0].String() == "*"
		if isWildcardOnly || !host.Matches(key) {
			continue
		}

		matched = true
		for _, node := range host.Nodes {
			switch t := node.(type) {
			case *ssh_config.KV:
				if user != "" && strings.ToLower(t.Key) == "user" {
					t.Value = user
				}
				if hostName != "" && strings.ToLower(t.Key) == "hostname" {
					t.Value = hostName
				}
				if identityFile != "" && strings.ToLower(t.Key) == "identityfile" {
					t.Value = identityFile
				}
			}
		}
	}

	if !matched {
		fmt.Fprintf(os.Stderr, "host %s not found in ssh config file, skipping update\n", key)
		os.Exit(0)
	} else {
		bits, _ := cfg.MarshalText()
		if err := os.WriteFile(sshConfigPath, bits, 0644); err != nil {
			panic(err)
		}
	}
}
