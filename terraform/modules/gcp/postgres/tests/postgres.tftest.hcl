mock_provider "google" {
  mock_resource "google_sql_database_instance" {
    defaults = {
      connection_name    = "proj:us-central1:relay"
      private_ip_address = "10.10.0.5"
      server_ca_cert     = [{ cert = "-----BEGIN CERTIFICATE-----", common_name = "", create_time = "", expiration_time = "", sha1_fingerprint = "" }]
    }
  }
  mock_resource "google_secret_manager_secret" {
    defaults = { id = "projects/proj/secrets/relay-admin-password" }
  }
}

mock_provider "random" {}

variables {
  project_id        = "proj"
  region            = "us-central1"
  name              = "relay"
  network_self_link = "projects/proj/global/networks/vpc"
  databases         = ["relaycontrol", "relayhistory", "hoopdb"]
}

run "defaults_are_private_and_protected" {
  command = apply

  assert {
    condition     = google_sql_database_instance.this.settings[0].ip_configuration[0].ipv4_enabled == false
    error_message = "No public IP."
  }
  assert {
    condition     = google_sql_database_instance.this.settings[0].ip_configuration[0].ssl_mode == "ENCRYPTED_ONLY"
    error_message = "TLS is required."
  }
  assert {
    condition     = google_sql_database_instance.this.deletion_protection && google_sql_database_instance.this.settings[0].deletion_protection_enabled
    error_message = "Deletion protection on both sides."
  }
  assert {
    condition     = google_sql_database_instance.this.settings[0].backup_configuration[0].enabled && google_sql_database_instance.this.settings[0].backup_configuration[0].point_in_time_recovery_enabled
    error_message = "Backups and PITR on."
  }
  assert {
    condition     = google_sql_database_instance.this.database_version == "POSTGRES_17" && google_sql_database_instance.this.settings[0].availability_type == "REGIONAL"
    error_message = "PostgreSQL 17, regional HA by default."
  }
  assert {
    condition     = google_sql_user.admin[0].password == null
    error_message = "The admin password must only be passed write-only."
  }
  assert {
    condition     = google_secret_manager_secret_version.admin[0].secret_data == null
    error_message = "The secret version must only be written write-only."
  }
  assert {
    condition     = length(google_sql_database.this) == 3
    error_message = "Requested databases are created."
  }
}

run "no_admin_user" {
  command = plan

  variables {
    admin_user = { create = false }
  }

  assert {
    condition     = length(google_sql_user.admin) == 0 && length(google_secret_manager_secret.admin) == 0
    error_message = "admin_user.create = false creates no user or secret."
  }
}

run "unencrypted_ssl_mode_refused" {
  command = plan

  variables {
    ssl_mode = "ALLOW_UNENCRYPTED_AND_ENCRYPTED"
  }

  expect_failures = [var.ssl_mode]
}
