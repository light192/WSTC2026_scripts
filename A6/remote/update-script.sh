#!/usr/bin/env bash
ifdown ens18
ifup ens19
git pull
ifup ens18
ifdown ens19