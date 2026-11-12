# Terraform Cato Bulk Terminal Server Rules Module

This module allows you to bulk import Terminal Server (TS) rules and sections from a JSON configuration file, and define the order of those rules and sections within the Cato policy. The Terminal Server policy is **flat** - no sub-policies exist for this type - and `cato_bulk_ts_move_rule` both orders and **publishes** the policy on every apply.

## Usage

The module reads a JSON configuration file that defines:
- **Rules**: Individual Terminal Server rules with their configurations
- **Sections**: Logical groupings for organizing rules
- **Rule ordering**: Defines which rules belong to which sections and their order within sections

### Basic Example

```hcl
module "ts_rules" {
  source = "catonetworks/bulk-ts-rules/cato"

  ts_rules_json_file_path = "${path.module}/config_data/all_ts_rules_and_sections.json"
}
```

### JSON Configuration Structure

The JSON file should contain a nested structure with the following key components:

- `data.policy.terminalServer.policy.rules[]` - Array of Terminal Server rules
- `data.policy.terminalServer.policy.sections[]` - Array of sections with index and name
- `data.policy.terminalServer.policy.rules_in_sections[]` - Mapping of rules to sections with ordering

#### Key Fields:

**Rules Array**: Each rule entry is wrapped as `{audit, rule, properties}` (ids retained for brownfield import) and contains standard TS rule properties:
- `allowedHostIP`: a global IP range reference (**required**) - `{ name }` or `{ id }`
- `excludeTraffic`: an optional list of global IP range references to exclude from the rule
- `name`, `description`, `enabled`, `section` - placement info

**Sections Array**: Defines sections with:
- `section_index`: The order of the section in the policy
- `section_name`: The display name of the section

**Rules in Sections Array**: Maps rules to sections with:
- `index_in_section`: The order of the rule within its section
- `section_name`: The section this rule belongs to
- `rule_name`: The name of the rule to place in the section

### How Rule Ordering Works

- Sections are ordered by `section_index` and rules within a section by `index_in_section`, both applied by `cato_bulk_ts_move_rule`.
- A rule whose `rules_in_sections` row has `section_name: ""` (or references a section not managed by this module) is excluded from the move resource - it lands at `LAST_IN_POLICY` and its order is creation order only. These rows are surfaced via the `unordered_rules` output.
- `cato_bulk_ts_move_rule` is this stack's single publisher: the rule/section resources only save to the draft policy. Without it, applies never go live.
- Terminal Server ships **disabled** on new tenants - set `policy_enabled = true` (via the module) or enable it in the CMA for published rules to take effect.

### Parameters

- `ts_rules_json_file_path`: Path to your JSON configuration file
- `policy_enabled`: (Optional) Manage the account-level Terminal Server policy toggle via `cato_terminal_server_policy`. `null` (default) leaves the toggle unmanaged; `true`/`false` manages it.
- `allow_empty_policy`: (Optional) Safety guard - `terraform plan` fails if the decoded JSON has 0 rules unless this is set `true`. Protects against a truncated export, a renamed upstream JSON key, or an accidentally wrong-tenant near-empty JSON file silently destroying the live policy.
- **Note:** Run applies with `-parallelism=1` when several module instances share an account.

## Working with Existing Rules (Brownfield Deployments)

For brownfield deployments where you have existing Terminal Server rules in your Cato Management Application, you can use the Cato CLI to export and import these rules into Terraform state.

### Installing and Configuring Cato CLI

1. **Install the Cato CLI:**
   ```bash
   pip3 install catocli
   ```

2. **Configure the CLI with your Cato credentials:**
   ```bash
   catocli configure set
   ```
   This will prompt you for your Cato Management Application credentials and account information.

### Exporting Existing Rules

To export your existing Terminal Server rules and sections into the JSON format required by this module:

```bash
catocli export ts_rules --json-filename all_ts_rules_and_sections.json
```

This command will generate a JSON file (root: `data.policy.terminalServer.policy`) containing all your existing TS rules and sections in the correct format for this Terraform module.

### Importing Existing Rules into Terraform State

Once you have the JSON configuration file, you can adopt the existing rules and sections into Terraform state. This is useful for:

- **Brownfield deployments**: Managing existing rules with Terraform
- **Backup and restore**: Restoring rules to a known good state after unintended changes
- **State management**: Bringing existing infrastructure under Terraform control

There are two ways to do this. Every `for_each` address in this module (`rules_by_name`, `sections_data`) is keyed by name, exactly matching the exported JSON's `rule.name` / `section_name` fields - that's why the import blocks below line up one-to-one with the JSON with no re-keying.

<details>
<summary>Option A (recommended) - native Terraform import blocks (migration.tf)</summary>

Requires Terraform >= 1.7. Create a one-shot `migration.tf` file beside your module call with one `import` block per resource type:

```hcl
# migration.tf - one-time adoption of existing Terminal Server rules/sections.
# Place beside the module call (same directory as main.tf), run once, then delete.

locals {
  ts_migration_json     = jsondecode(file("${path.module}/config_data/all_ts_rules_and_sections.json"))
  ts_migration_policy   = local.ts_migration_json.data.policy.terminalServer.policy
  ts_migration_sections = { for s in local.ts_migration_policy.sections : s.section_name => s.section_id }
  ts_migration_rules    = { for rw in local.ts_migration_policy.rules : rw.rule.name => rw.rule.id }
}

import {
  for_each = local.ts_migration_sections
  to       = module.ts_rules.cato_terminal_server_section.sections[each.key]
  id       = each.value
}

import {
  for_each = local.ts_migration_rules
  to       = module.ts_rules.cato_terminal_server_rule.rules[each.key]
  id       = each.value
}
```

`cato_bulk_ts_move_rule` is plan-time orchestration - it republishes the whole policy on every apply and has no persisted object of its own to import, so it never appears in `migration.tf`. Same for the optional `cato_terminal_server_policy` enable/disable toggle: it's a tenant-wide singleton with no name/`for_each` to key an import block on.

Preview the adoption before anything touches state:

```bash
terraform plan
```

Expect `N to import, 0 to add, 0 to change, 0 to destroy` (plus `cato_bulk_ts_move_rule` showing as an add, since it's never imported). Any non-zero "to change" on the imported resources means the JSON export is stale relative to the live policy - **re-export** (`catocli export ts_rules --json-filename all_ts_rules_and_sections.json`) and regenerate the locals above, rather than letting `terraform apply` overwrite the live policy with stale config.

Once the plan is clean, adopt the resources into state:

```bash
terraform apply
```

Then delete `migration.tf` - its job is done, and leaving it in place just re-runs the same (no-op) import blocks on every future plan.

</details>

<details>
<summary>Option B - catocli import ts_rules_to_tf (imperative alternative)</summary>

An imperative alternative to Option A, for when native import blocks aren't practical (e.g. Terraform < 1.7, or scripting a fully automated onboarding pipeline). Unlike Option A, this mutates Terraform state immediately - there is no plan preview before the import happens.

```bash
catocli import ts_rules_to_tf config_data/all_ts_rules_and_sections.json \
  --module-name module.ts_rules --auto-approve
terraform plan   # expect: only cato_bulk_ts_move_rule to add
```

**Parameters:**
- `config_data/all_ts_rules_and_sections.json`: Path to your exported JSON file
- `--module-name module.ts_rules`: The name of your Terraform module instance

</details>

### Typical Brownfield Workflow

1. **Export existing rules:**
   ```bash
   catocli export ts_rules --json-filename all_ts_rules_and_sections.json
   ```

2. **Create your Terraform configuration:**
   ```hcl
   module "ts_rules" {
     source = "catonetworks/bulk-ts-rules/cato"

     ts_rules_json_file_path = "${path.module}/config_data/all_ts_rules_and_sections.json"
   }
   ```

3. **Adopt existing state (Option A - recommended):** create `migration.tf` with the import blocks shown above, then:
   ```bash
   terraform plan    # preview: expect only "to import" (plus the move resource to add)
   terraform apply   # adopt into state
   ```
   Delete `migration.tf` afterwards. (Option B: `catocli import ts_rules_to_tf config_data/all_ts_rules_and_sections.json --module-name module.ts_rules` - imperative, no plan preview.)

4. **Run Terraform plan to verify:**
   ```bash
   terraform plan
   ```
   This should show no further changes if the import was successful.

### Backup and Restore Workflow

If unintended changes are made directly to rules and sections in the Cato Management Application, you can restore to the last known good state:

1. **Apply your last known good configuration:**
   ```bash
   terraform apply
   ```
   This will restore rules and sections to match your Terraform configuration and republish via `cato_bulk_ts_move_rule`.

2. **Alternatively, re-export and compare:**
   ```bash
   catocli export ts_rules --json-filename all_ts_rules_and_sections.json
   # Compare with your existing JSON file to identify changes
   ```

## Using Module Outputs

The module provides outputs that can be used for monitoring, auditing, integration with other systems, and operational insights. Below are practical examples of how to use these outputs in your Terraform configuration.

<details>
<summary>Click to expand example client-side outputs</summary>

```hcl
# Basic deployment information
output "deployment_info" {
  description = "Basic information about the Terminal Server deployment"
  value = {
    total_sections = module.ts_rules.deployment_summary.sections
    total_rules    = module.ts_rules.deployment_summary.rules
  }
}

# Quick reference for rule and section IDs
output "quick_reference" {
  description = "Quick reference maps for rules and sections"
  value = {
    section_ids = module.ts_rules.section_ids
    rule_ids    = module.ts_rules.rule_ids
  }
}

# Rules that could not be ordered by the move resource
output "rules_needing_attention" {
  description = "rules_in_sections rows excluded from cato_bulk_ts_move_rule - creation-order only"
  value       = module.ts_rules.unordered_rules
}

# Example: For integration with monitoring systems
output "monitoring_metrics" {
  description = "Example metrics that could be sent to monitoring systems"
  value = {
    deployment_timestamp = timestamp()
    total_ts_rules        = module.ts_rules.deployment_summary.rules
    total_ts_sections      = module.ts_rules.deployment_summary.sections
    unordered_rule_count   = length(module.ts_rules.unordered_rules)
  }
}
```
</details>

### Output Use Cases

- **`deployment_info`**: Quick deployment overview for dashboards
- **`quick_reference`**: ID mappings for referencing resources in other modules
- **`rules_needing_attention`**: Identifying rules excluded from automated ordering (`section_name: ""`) for manual review
- **`monitoring_metrics`**: Metrics formatted for monitoring systems

<!-- BEGIN_TF_DOCS -->
## Requirements

| Name | Version |
|------|---------|
| <a name="requirement_terraform"></a> [terraform](#requirement\_terraform) | >= 1.5.0 |
| <a name="requirement_cato"></a> [cato](#requirement\_cato) | >= 1.3.1 |

## Providers

| Name | Version |
|------|---------|
| <a name="provider_cato"></a> [cato](#provider\_cato) | >= 1.3.1 |

## Modules

No modules.

## Resources

| Name | Type |
|------|------|
| [cato_bulk_ts_move_rule.all_ts_rules](https://registry.terraform.io/providers/catonetworks/cato/latest/docs/resources/bulk_ts_move_rule) | resource |
| [cato_terminal_server_policy.policy](https://registry.terraform.io/providers/catonetworks/cato/latest/docs/resources/terminal_server_policy) | resource |
| [cato_terminal_server_rule.rules](https://registry.terraform.io/providers/catonetworks/cato/latest/docs/resources/terminal_server_rule) | resource |
| [cato_terminal_server_section.sections](https://registry.terraform.io/providers/catonetworks/cato/latest/docs/resources/terminal_server_section) | resource |

## Inputs

| Name | Description | Type | Default | Required |
|------|-------------|------|---------|:--------:|
| <a name="input_allow_empty_policy"></a> [allow\_empty\_policy](#input\_allow\_empty\_policy) | Safety guard: fail planning when the policy JSON contains 0 rules unless explicitly allowed. Protects against a truncated or wrong-tenant export destroying the live policy. Set true only for intentional greenfield/teardown. | `bool` | `false` | no |
| <a name="input_policy_enabled"></a> [policy\_enabled](#input\_policy\_enabled) | Manage the account-level Terminal Server policy toggle. null leaves the toggle unmanaged; true/false manages it via cato\_terminal\_server\_policy. | `bool` | `null` | no |
| <a name="input_ts_rules_json_file_path"></a> [ts\_rules\_json\_file\_path](#input\_ts\_rules\_json\_file\_path) | Path to the Terminal Server JSON export produced by `catocli export ts_rules` (data.policy.terminalServer.policy root). | `string` | n/a | yes |

## Outputs

| Name | Description |
|------|-------------|
| <a name="output_deployment_summary"></a> [deployment\_summary](#output\_deployment\_summary) | Counts of managed Terminal Server objects. |
| <a name="output_rule_ids"></a> [rule\_ids](#output\_rule\_ids) | Map of rule name to rule id. |
| <a name="output_section_ids"></a> [section\_ids](#output\_section\_ids) | Map of section name to section id. |
| <a name="output_unordered_rules"></a> [unordered\_rules](#output\_unordered\_rules) | rules\_in\_sections rows excluded from cato\_bulk\_ts\_move\_rule (no managed section to order within). |
<!-- END_TF_DOCS -->
