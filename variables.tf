variable "ts_rules_json_file_path" {
  description = "Path to the Terminal Server JSON export produced by `catocli export ts_rules` (data.policy.terminalServer.policy root)."
  type        = string
}

variable "policy_enabled" {
  description = "Manage the account-level Terminal Server policy toggle. null leaves the toggle unmanaged; true/false manages it via cato_terminal_server_policy."
  type        = bool
  default     = null
}
