variable "extra_vars" {
  description = "ansible_extra_vars of the platform: role variables that override the defaults here."
  type        = any
  default     = {}
}

variable "velero" {
  description = "The platform's velero variable."
  type = object({
    enabled                  = optional(bool, false)
    bucket                   = optional(string, "")
    s3_url                   = optional(string, "")
    region                   = optional(string, "minio")
    access_key               = optional(string, "")
    secret_key               = optional(string, "")
    insecure_skip_tls_verify = optional(bool, false)
    volume_backups           = optional(bool, true)
    schedule                 = optional(string, "0 3 * * *")
    ttl                      = optional(string, "720h")
  })
  default   = {}
  sensitive = true
  nullable  = false
}
