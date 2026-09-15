variable "bridge_interface" {
  description = "The bridge the VLANs are created on. Naming only: this module does not modify the bridge in this stage."
  type        = string
  default     = "bridge"
}

variable "switch_name" {
  description = "Short device name, used only in object comments so managed objects are identifiable."
  type        = string
  default     = "crs326"
}
