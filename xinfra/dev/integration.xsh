##! Integration dispatcher.

use integration.commands as commands_case
use integration.dirs as dirs_case
use integration.example as example_case
use integration.facts as facts_case
use integration.files as files_case
use integration.hostile as hostile_case
use integration.large_binary as large_binary_case
use integration.lock as lock_case
use integration.multi_host as multi_host_case
use integration.packages as packages_case
use integration.plans as plans_case
use integration.privilege as privilege_case
use integration.secrets as secrets_case
use integration.services as services_case
use integration.transport as transport_case
use integration.users as users_case

cli main(case: Str = "all") [fs, process, env, time, error, io] {
  if case == "example" or case == "all" {
    match example_case.check_example() {
      Ok(_) => {}
      Err(error) => fail error.message
    }
  }

  if case == "hostile" or case == "all" {
    match hostile_case.check_hostile() {
      Ok(_) => {}
      Err(error) => fail error.message
    }
  }

  if case == "large-binary" or case == "all" {
    match large_binary_case.check_large_binary() {
      Ok(_) => {}
      Err(error) => fail error.message
    }
  }

  if case == "privilege" or case == "all" {
    match privilege_case.check_privilege() {
      Ok(_) => {}
      Err(error) => fail error.message
    }
  }

  if case == "transport" or case == "all" {
    match transport_case.execute() {
      Ok(_) => {}
      Err(message) => fail message
    }
  }

  if case == "facts" or case == "all" {
    match facts_case.execute() {
      Ok(_) => {}
      Err(message) => fail message
    }
  }

  if case == "dirs,symlinks" or case == "dirs" or case == "symlinks" or case == "all" {
    match dirs_case.check_dirs() {
      Ok(_) => {}
      Err(message) => fail message
    }
  }

  if case == "files" or case == "all" {
    match files_case.check_files() {
      Ok(_) => {}
      Err(message) => fail message
    }
  }

  if case == "packages" or case == "all" {
    match packages_case.check_packages() {
      Ok(_) => {}
      Err(message) => fail message
    }
  }

  if case == "users" or case == "all" {
    match users_case.check_users() {
      Ok(_) => {}
      Err(message) => fail message
    }
  }

  if case == "commands" or case == "commands,services" or case == "all" {
    match commands_case.check_commands() {
      Ok(_) => {}
      Err(message) => fail message
    }
  }

  if case == "services" or case == "commands,services" or case == "all" {
    match services_case.check_services() {
      Ok(_) => {}
      Err(message) => fail message
    }
  }

  let multi_cases = case == "multi-host,ordering,lock,cancel" or case == "multi-host,ordering,cancel,lock"
  if case == "multi-host" or case == "ordering" or case == "cancel" or multi_cases or case == "all" {
    match multi_host_case.check_multi_host() {
      Ok(_) => {}
      Err(message) => fail message
    }
  }

  if case == "lock" or multi_cases or case == "all" {
    match lock_case.check_lock() {
      Ok(_) => {}
      Err(message) => fail message
    }
  }

  if case == "secrets" or case == "reporting" or case == "secrets,reporting" or case == "all" {
    match secrets_case.check_secrets() {
      Ok(_) => {}
      Err(error) => fail error.message
    }
  }

  if case == "stale-plan" or case == "plans" or case == "all" {
    match plans_case.check_plans() {
      Ok(_) => {}
      Err(error) => fail error.message
    }
  }

  let known = [
    "all",
    "example",
    "hostile",
    "large-binary",
    "privilege",
    "transport",
    "facts",
    "dirs,symlinks",
    "dirs",
    "symlinks",
    "files",
    "packages",
    "users",
    "commands",
    "services",
    "commands,services",
    "multi-host",
    "ordering",
    "cancel",
    "lock",
    "multi-host,ordering,lock,cancel",
    "multi-host,ordering,cancel,lock",
    "secrets",
    "reporting",
    "secrets,reporting",
    "stale-plan",
    "plans",
  ]
  if case not in known {
    fail f"unknown integration case {case}"
  }
}
