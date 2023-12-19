// Copyright 2012-2017 the u-root Authors. All rights reserved
// Use of this source code is governed by a BSD-style
// license that can be found in the LICENSE file.

// This is winterfell init script
package main

import (
	"log"
	"os"
	"os/exec"
	"strings"
)

var (
	commands = []string{
		"/bbin/insmod /lib/modules/nvme-core.ko",
		"/bbin/insmod /lib/modules/nvme.ko",
		"/bbin/insmod /lib/modules/libata.ko",
		"/bbin/insmod /lib/modules/libahci.ko",
		"/bbin/insmod /lib/modules/ahci.ko",
		"/bbin/rsdp",
	}
)

func main() {
	for _, line := range commands {
		log.Printf("Executing Command: %v", line)
		cmdSplit := strings.Split(line, " ")
		if len(cmdSplit) == 0 {
			continue
		}

		cmd := exec.Command(cmdSplit[0], cmdSplit[1:]...)
		cmd.Stdin = os.Stdin
		cmd.Stderr = os.Stderr
		cmd.Stdout = os.Stdout
		if err := cmd.Run(); err != nil {
			log.Print(err)
		}

	}
	log.Print("Uinit Done!")
}
