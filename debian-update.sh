#!/bin/bash
sudo apt update -y
sudo DEBIAN_FRONTEND=noninteractive DEBIAN_PRIORITY=critical apt -y -qq -o DPkg::options::="--force-confdef" -o DPkg::options::="--force-confold" dist-upgrade
