/*
Copyright (c) 2016, UPMC Enterprises
All rights reserved.
Redistribution and use in source and binary forms, with or without
modification, are permitted provided that the following conditions are met:
    * Redistributions of source code must retain the above copyright
      notice, this list of conditions and the following disclaimer.
    * Redistributions in binary form must reproduce the above copyright
      notice, this list of conditions and the following disclaimer in the
      documentation and/or other materials provided with the distribution.
    * Neither the name UPMC Enterprises nor the
      names of its contributors may be used to endorse or promote products
      derived from this software without specific prior written permission.
THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS" AND
ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED
WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE
DISCLAIMED. IN NO EVENT SHALL UPMC ENTERPRISES BE LIABLE FOR ANY
DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES
(INCLUDING, BUT NOT LIMITED TO, PR)
OCUREMENT OF SUBSTITUTE GOODS OR SERVICES;
LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND
ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT
(INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE OF THIS
*/

variable "ssh-key-name" {}

variable "cluster-name" {}

variable "aws-access-key-id" {
  // If empty, IAM will be used.
  default = ""
}

variable "aws-secret-access-key" {
  // If empty, IAM will be used.
  default = ""
}

variable "milpa-installer-url" {
  // The URL to download the Milpa installer from.
  default = "https://download.elotl.co/bcox-milpa-kiyot-crds-installer"
}

variable "itzo-url" {
  // The URL to download the node agent from.
  default = "http://itzo-download.s3.amazonaws.com"
}

variable "itzo-version" {
  // The version of node agent to use.
  default = "latest"
}

variable "license-key" {}

variable "license-id" {}

variable "license-username" {}

variable "license-password" {}

variable "region" {
  default = "us-east-1"
}

variable "master-userdata" {
  default = "master.sh"
}

variable "worker-userdata" {
  default = "worker.sh"
}

variable "milpa-worker-userdata" {
  default = "milpa-worker.sh"
}

variable "vpc-cidr" {
  default = "10.0.0.0/16"
}

variable "pod-cidr" {
  default = "172.20.0.0/16"
}

variable "service-cidr" {
  default = "10.96.0.0/12"
}

variable "workers" {
  // Number of regular kubelet workers to create in the cluster.
  default = 0
}

variable "milpa-workers" {
  // Number of Milpa workers to create in the cluster.
  default = 1
}

variable "number-of-subnets" {
  // Number of subnets to create in the VPC. Workers and Milpa pods will be
  // created in a random subnet.
  default = 3
}

variable "k8s-version" {
  // You can specify a specific version, for example "1.13.5*", or "*" for
  // using the latest version available. Don't forget the last asterisk, since
  // packages are named 1.13.5-00, 1.14.0-00, etc.
  default = "*"
}

variable "k8stoken" {
  default = ""
}
