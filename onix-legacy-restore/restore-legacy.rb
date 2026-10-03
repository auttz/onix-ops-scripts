#!/usr/bin/env ruby
# frozen_string_literal: true
#
# One-off restore script for Onix Legacy (x073 item 4).
#
# Restores a Postgres dump into a given postgres pod, and a storage/images
# archive into a given app pod. Runs directly on a plain host that has
# `kubectl` configured against the target cluster — no container, no
# cronjob, nothing to install beyond `kubectl` itself and the `unzip`/`tar`
# binaries (already on virtually every Linux box).
#
# Loosely modeled on the existing
# https://github.com/wintech-thai/onix-jobs/blob/main/scripts/restore-storage-and-db.bash
# but simplified: no GCS download step (the dump/zip are expected to already
# be sitting next to this script, or wherever INPUT_DIR points), and the SQL
# restore goes through `kubectl exec` + `psql` INSIDE the postgres pod
# instead of a direct external `psql` connection (the pod doesn't need to be
# network-reachable from this host that way).
#
# Usage:
#   1. Put the .sql/.dump file and the .zip file in INPUT_DIR (defaults to
#      this script's own directory) — or set SQL_FILE / ZIP_FILE explicitly
#      below if the auto-detected pick (first *.sql/*.dump, first *.zip) is
#      wrong.
#   2. Adjust the CONFIG block below for the target namespace/pods.
#   3. ruby restore-legacy.rb
#
# Safe to re-run: every step is unconditional (kubectl cp overwrites, psql
# just re-applies the dump, tar -xvf overwrites extracted files) — there is
# no "already done, skip" state tracking, by design, since this is meant to
# be re-run on demand. NOTE: whether re-running the SQL restore itself is
# fully clean (no duplicate-row/already-exists errors) depends on whether
# the dump file includes DROP/TRUNCATE statements before its INSERTs — that
# wasn't inspected here since the dump wasn't downloaded while writing this
# script. If a second run prints errors from existing rows/constraints,
# check the dump's own contents before assuming the script is broken.

require 'open3'
require 'fileutils'
require 'tmpdir'

# ============================ CONFIG — edit me ============================
NAMESPACE   = ENV['NAMESPACE']   || 'onix-dev'
PG_POD      = ENV['PG_POD']      || 'postgresql-0'
APP_POD     = ENV['APP_POD']     || 'onix-dev-onix-legacy-api-acd-fcf48bcd6-wbrpb'

PG_USER     = ENV['PG_USER']     || 'postgres'
PG_DATABASE = ENV['PG_DATABASE'] || 'postgres'
# Pod-local psql needs a password unless the pod's pg_hba.conf trusts local
# connections — pass it via env rather than hardcoding here (e.g. read it
# straight off the postgres pod itself: `kubectl exec -n NS POD -- env |
# grep POSTGRES_PASSWORD`).
PG_PASSWORD = ENV['PG_PASSWORD'] || ''

INPUT_DIR   = ENV['INPUT_DIR']   || __dir__
SQL_FILE    = ENV['SQL_FILE']    || Dir.glob(File.join(INPUT_DIR, '*.{sql,dump}')).first
ZIP_FILE    = ENV['ZIP_FILE']    || Dir.glob(File.join(INPUT_DIR, '*.zip')).first

# Where the extracted storage archive lands inside APP_POD.
POD_STORAGE_DIR = '/wis/data/storage'
# ============================================================================

def run(cmd)
  puts "+ #{cmd}"
  output, status = Open3.capture2e(cmd)
  puts output unless output.strip.empty?
  raise "Command failed (exit #{status.exitstatus}): #{cmd}" unless status.success?

  output
end

def restore_database
  puts "=== [1/2] Restoring database dump into pod #{PG_POD} (ns=#{NAMESPACE}) ==="
  raise "SQL/dump file not found in #{INPUT_DIR} (set SQL_FILE explicitly if needed)" unless SQL_FILE && File.exist?(SQL_FILE)

  puts "Using dump file: #{SQL_FILE}"
  remote_path = "/tmp/#{File.basename(SQL_FILE)}"

  run(%(kubectl cp "#{SQL_FILE}" #{NAMESPACE}/#{PG_POD}:#{remote_path}))

  psql_cmd = if PG_PASSWORD.empty?
               %(kubectl exec -i -n #{NAMESPACE} #{PG_POD} -- psql -U #{PG_USER} -d #{PG_DATABASE} -f #{remote_path})
             else
               %(kubectl exec -i -n #{NAMESPACE} #{PG_POD} -- env PGPASSWORD=#{PG_PASSWORD} psql -U #{PG_USER} -d #{PG_DATABASE} -f #{remote_path})
             end
  run(psql_cmd)

  puts "Database restore complete."
end

def restore_storage
  puts "=== [2/2] Restoring storage/images into pod #{APP_POD} (ns=#{NAMESPACE}) ==="
  raise "Zip file not found in #{INPUT_DIR} (set ZIP_FILE explicitly if needed)" unless ZIP_FILE && File.exist?(ZIP_FILE)

  puts "Using zip file: #{ZIP_FILE}"
  work_dir = Dir.mktmpdir('restore-legacy-')

  begin
    run(%(unzip -o "#{ZIP_FILE}" -d "#{work_dir}"))

    # Spec: the zip is expected to extract into a folder literally named "tmp".
    extracted_dir = File.join(work_dir, 'tmp')
    raise "Expected the zip to extract into a 'tmp' folder — found none under #{work_dir}" unless Dir.exist?(extracted_dir)

    tar_path = File.join(work_dir, 'tmp.tar')
    run(%(tar -cf "#{tar_path}" -C "#{work_dir}" tmp))

    remote_tar = "#{POD_STORAGE_DIR}/tmp.tar"
    run(%(kubectl exec -n #{NAMESPACE} #{APP_POD} -- mkdir -p #{POD_STORAGE_DIR}))
    run(%(kubectl cp "#{tar_path}" #{NAMESPACE}/#{APP_POD}:#{remote_tar}))
    run(%(kubectl exec -i -n #{NAMESPACE} #{APP_POD} -- tar -xvf #{remote_tar} -C #{POD_STORAGE_DIR}))
  ensure
    FileUtils.remove_entry(work_dir)
  end

  puts "Storage restore complete — files extracted under #{POD_STORAGE_DIR}/tmp"
end

restore_database
restore_storage
puts '=== All done ==='
