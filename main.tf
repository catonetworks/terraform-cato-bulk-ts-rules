# terraform-cato-bulk-ts-rules
#
# Bulk-manages the Cato Terminal Server (terminalServer) policy from one JSON
# export produced by `catocli export ts_rules`:
#   sections[] / rules[] / rules_in_sections[] - flat policy, no sub-policies.
# cato_bulk_ts_move_rule applies ordering and republishes.
# Rule fields: allowedHostIP (global IP range ref, required), excludeTraffic (global IP range refs).

locals {
  ts_json = jsondecode(file("${var.ts_rules_json_file_path}"))
  ts      = local.ts_json.data.policy.terminalServer.policy

  sections_data_raw      = try(local.ts.sections, [])
  rules_data_raw         = try(local.ts.rules, [])
  rules_in_sections_data = try(local.ts.rules_in_sections, [])

  sections_data = {
    for s in local.sections_data_raw : s.section_name => s
  }

  rules_by_name = {
    for rw in local.rules_data_raw : rw.rule.name => rw
  }

  move_section_data = {
    for name, s in local.sections_data : name => {
      section_index = s.section_index
    }
  }

  move_rule_data = {
    for row in local.rules_in_sections_data :
    row.rule_name => {
      index_in_section = row.index_in_section
      section_name     = row.section_name
    }
    if row.section_name != "" && contains(keys(local.sections_data), row.section_name)
  }

  unordered_rules_data = [
    for row in local.rules_in_sections_data : row
    if !contains(keys(local.move_rule_data), try(row.rule_name, ""))
  ]

  rule_bodies = {
    for name, rw in local.rules_by_name : name => merge(
      {
        name            = rw.rule.name
        enabled         = try(rw.rule.enabled, true)
        allowed_host_ip = can(rw.rule.allowedHostIP.name) ? { name = rw.rule.allowedHostIP.name } : { id = rw.rule.allowedHostIP.id }
      },
      try(rw.rule.description, "") != "" ? { description = rw.rule.description } : {},
      try(length(rw.rule.excludeTraffic), 0) > 0 ? {
        exclude_traffic = [for x in rw.rule.excludeTraffic : can(x.name) ? { name = x.name } : { id = x.id }]
      } : {}
    )
  }
}

# Optional account-level policy toggle (Terminal Server ships disabled on new
# tenants - without enabling it, published rules have no effect).
resource "cato_terminal_server_policy" "policy" {
  count   = var.policy_enabled == null ? 0 : 1
  enabled = var.policy_enabled
}

resource "cato_terminal_server_section" "sections" {
  for_each = local.sections_data
  at = {
    position = "LAST_IN_POLICY"
  }
  section = {
    name = each.value.section_name
  }
}

resource "cato_terminal_server_rule" "rules" {
  depends_on = [cato_terminal_server_section.sections]
  for_each   = local.rules_by_name

  at = contains(keys(local.sections_data), each.value.rule.section.name) ? {
    position = "LAST_IN_SECTION"
    ref      = cato_terminal_server_section.sections[each.value.rule.section.name].id
    } : {
    position = "LAST_IN_POLICY"
  }

  rule = local.rule_bodies[each.key]
}

# Ordering + republish on changes.
resource "cato_bulk_ts_move_rule" "all_ts_rules" {
  depends_on = [cato_terminal_server_section.sections, cato_terminal_server_rule.rules]

  section_data = local.move_section_data
  rule_data    = local.move_rule_data
}
