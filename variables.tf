variable "ts_rules_json_file_path" {
  description = "Path to the Terminal Server JSON export produced by `catocli export ts_rules` (data.policy.terminalServer.policy root)."
  type        = string
}

variable "policy_enabled" {
  description = "Manage the account-level Terminal Server policy toggle. null leaves the toggle unmanaged; true/false manages it via cato_terminal_server_policy."
  type        = bool
  default     = null
}

variable "allow_empty_policy" {
  description = "Safety guard: fail planning when the policy JSON contains 0 rules unless explicitly allowed. Protects against a truncated or wrong-tenant export destroying the live policy. Set true only for intentional greenfield/teardown."
  type        = bool
  default     = false
}
