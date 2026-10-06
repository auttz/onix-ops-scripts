#!/usr/bin/env ruby
# Standalone WordPress restore script — no CronJob, no dependency on the
# onix-v2-jobs repo. Downloads a backup zip (db-*.sql.gz + files-*.tar.gz,
# same format produced by onix-v2-jobs' app-backup.rb) from GCS via its
# S3-compatible interop API, then restores it into a MySQL pod + WordPress
# pod via kubectl.
#
# Run directly from the command line:
#   S3_KEY=... S3_SECRET=... S3_URL=... S3_BUCKET=... S3_FILE=... \
#   NAMESPACE=... WP_APP_POD=... WP_MYSQL_POD=... ruby restore-wordpress.rb
#
# Safe to re-run: every run fully overwrites the database (DROP + CREATE)
# and the WordPress data directory with whatever S3_FILE currently points
# at — so to restore a newer day's backup, just change S3_FILE and run
# again.
#
# Required env vars:
#   S3_KEY, S3_SECRET  - GCS HMAC interop credentials (same ones used for backup)
#   S3_URL             - GCS S3-compatible endpoint (same one used for backup)
#   S3_BUCKET          - bucket name, e.g. devhubs-backup
#   S3_FILE            - object key WITHOUT the bucket, e.g. aldamex/wp-backup-gke-20261003220009.zip
#   NAMESPACE          - k8s namespace the WordPress site runs in
#   WP_APP_POD         - WordPress pod name
#   WP_MYSQL_POD       - MySQL pod name
#
# Optional:
#   APP_DATA_PATH      - WordPress data dir inside the app pod (default /bitnami/wordpress)
#
# Needs the aws-sdk-s3 gem: gem install aws-sdk-s3

require 'aws-sdk-s3'
require 'open3'
require 'fileutils'
require 'shellwords'

def env!(name)
  v = ENV[name]
  if v.nil? || v.strip.empty?
    puts "ERROR: missing required env var #{name}"
    exit 1
  end
  v
end

S3_KEY        = env!('S3_KEY')
S3_SECRET     = env!('S3_SECRET')
S3_URL        = env!('S3_URL')
S3_BUCKET     = env!('S3_BUCKET')
S3_FILE       = env!('S3_FILE')
NAMESPACE     = env!('NAMESPACE')
WP_APP_POD    = env!('WP_APP_POD')
WP_MYSQL_POD  = env!('WP_MYSQL_POD')
APP_DATA_PATH = ENV['APP_DATA_PATH'] || '/bitnami/wordpress'

TMP_DIR = '/tmp'

$stdout.sync = true

# Runs a shell command, printing its FULL combined stdout+stderr (never
# truncated) and exiting immediately with that output still on screen if it
# fails — so whatever actually broke is always visible, not swallowed.
def run!(cmd, step)
  puts ">>> #{step}"
  output, status = Open3.capture2e(cmd)
  puts output
  unless status.success?
    puts "ERROR: #{step} failed (exit #{status.exitstatus})"
    exit 1
  end
  output
end

def pod_restart_count(namespace, pod)
  out, status = Open3.capture2e("kubectl get pod #{pod} -n #{namespace} -o jsonpath={.status.containerStatuses[0].restartCount}")
  return nil unless status.success?
  out.strip.to_i
end

def pod_phase(namespace, pod)
  out, status = Open3.capture2e("kubectl get pod #{pod} -n #{namespace} -o jsonpath={.status.phase}")
  return nil unless status.success?
  out.strip
end

# Resolves the MySQL user/password + restores the dump, run inside the
# MySQL pod. Password is read from the pod's own env vars (set by the
# Bitnami chart), checking the "_FILE" pointer variant first — same
# house convention as onix-v2-jobs' db-restore-bitnami.bash, ported inline
# here so this script has no external file dependency.
MYSQL_RESTORE_SCRIPT = <<~'SCRIPT'
  set -e
  resolve_secret() {
    local file_var="$1" plain_var="$2" file_path
    file_path="${!file_var}"
    if [ -n "$file_path" ] && [ -f "$file_path" ]; then
      cat "$file_path"
    else
      echo "${!plain_var}"
    fi
  }
  DB_USER="${MYSQL_USER:-root}"
  DB_NAME="${MYSQL_DATABASE}"
  if [ "$DB_USER" = "root" ]; then
    DB_PASSWORD=$(resolve_secret MYSQL_ROOT_PASSWORD_FILE MYSQL_ROOT_PASSWORD)
  else
    DB_PASSWORD=$(resolve_secret MYSQL_PASSWORD_FILE MYSQL_PASSWORD)
  fi
  echo "Restoring into MySQL db=[$DB_NAME] user=[$DB_USER]"
  mysql -u"$DB_USER" -p"$DB_PASSWORD" -e "DROP DATABASE IF EXISTS $DB_NAME; CREATE DATABASE $DB_NAME;"
  gunzip -c "/tmp/restore-db.sql.gz" | mysql -u"$DB_USER" -p"$DB_PASSWORD" "$DB_NAME"
SCRIPT

start_time = Time.now
puts "=== WordPress restore starting ==="
puts "NAMESPACE=#{NAMESPACE}  WP_APP_POD=#{WP_APP_POD}  WP_MYSQL_POD=#{WP_MYSQL_POD}"
puts "S3_BUCKET=#{S3_BUCKET}  S3_FILE=#{S3_FILE}"
puts ""

app_restart_before   = pod_restart_count(NAMESPACE, WP_APP_POD)
mysql_restart_before = pod_restart_count(NAMESPACE, WP_MYSQL_POD)

s3 = Aws::S3::Client.new(
  endpoint:          S3_URL,
  access_key_id:     S3_KEY,
  secret_access_key: S3_SECRET,
  region:            'auto',
  force_path_style:  false,
  # No timeouts = a dropped connection hangs the download forever with zero
  # feedback (confirmed live: stalled 36+ minutes at the same byte count
  # with no error). http_read_timeout caps how long a single stalled read
  # can block before raising, so a dead connection surfaces quickly instead.
  http_open_timeout: 10,
  http_read_timeout: 60,
)

final_zip = File.basename(S3_FILE)
local_zip = "#{TMP_DIR}/#{final_zip}"

puts "[1/6] Downloading s3://#{S3_BUCKET}/#{S3_FILE} ..."

MAX_DOWNLOAD_ATTEMPTS = 3
head = s3.head_object(bucket: S3_BUCKET, key: S3_FILE)
total_size = head.content_length
puts "Total size: #{(total_size / 1024.0 / 1024.0).round(1)} MB"

attempt = 0
begin
  attempt += 1
  downloaded = 0
  last_report = Time.now
  File.open(local_zip, 'wb') do |file|
    s3.get_object(bucket: S3_BUCKET, key: S3_FILE) do |chunk|
      file.write(chunk)
      downloaded += chunk.bytesize
      if Time.now - last_report >= 10
        pct = (downloaded.to_f / total_size * 100).round(1)
        puts "  ... #{(downloaded / 1024.0 / 1024.0).round(1)} / #{(total_size / 1024.0 / 1024.0).round(1)} MB (#{pct}%)"
        last_report = Time.now
      end
    end
  end
rescue => e
  puts "WARN : download attempt #{attempt}/#{MAX_DOWNLOAD_ATTEMPTS} failed: #{e.class}: #{e.message}"
  if attempt < MAX_DOWNLOAD_ATTEMPTS
    sleep 5
    retry
  end
  puts "ERROR: download failed after #{MAX_DOWNLOAD_ATTEMPTS} attempts"
  puts e.backtrace.join("\n")
  exit 1
end
puts "Downloaded to #{local_zip}"

unzip_dir = "#{TMP_DIR}/restore-unzip"
FileUtils.rm_rf(unzip_dir)
FileUtils.mkdir_p(unzip_dir)
run!("cd #{unzip_dir} && unzip -o #{local_zip}", "[2/6] Unpacking #{final_zip}")

db_dump_gz = Dir.glob("#{unzip_dir}/db-*.sql.gz").max_by { |f| File.mtime(f) }
files_tar  = Dir.glob("#{unzip_dir}/files-*.tar.gz").max_by { |f| File.mtime(f) }

if db_dump_gz.nil?
  puts "ERROR: could not find db-*.sql.gz inside #{final_zip}"
  exit 1
end
if files_tar.nil?
  puts "ERROR: could not find files-*.tar.gz inside #{final_zip}"
  exit 1
end
puts "DB dump: #{File.basename(db_dump_gz)}"
puts "Files archive: #{File.basename(files_tar)}"

# [3/6] Copy DB dump into the MySQL pod (always under a fixed name so the
# restore script above doesn't need to know the real backup filename).
run!("kubectl cp #{db_dump_gz} -n #{NAMESPACE} #{WP_MYSQL_POD}:/tmp/restore-db.sql.gz", "[3/6] Copying DB dump into MySQL pod")

# [4/6] Restore the database inside the MySQL pod.
run!("kubectl exec -i -n #{NAMESPACE} #{WP_MYSQL_POD} -- bash -c #{Shellwords.escape(MYSQL_RESTORE_SCRIPT)}", "[4/6] Restoring MySQL database")

# [5/6] Copy the files archive into the WordPress pod.
run!("kubectl cp #{files_tar} -n #{NAMESPACE} #{WP_APP_POD}:/tmp/restore-files.tar.gz", "[5/6] Copying files archive into WordPress pod")

# [6/6] Extract into a FRESH temp dir first (tar creates it, so there's no
# permission conflict trying to chmod/utime the pre-existing mount point),
# then `cp -rf` the contents over the real data dir:
#   -f  wp-config.php and a few others are deliberately left read-only by
#       Bitnami even to their own owning uid — force deletes+recreates them
#       instead of failing to open them for writing
#   (no -p/-a) avoids cp also trying to preserve/touch the pre-existing
#       target directory's own metadata, which fails the same
#       "Operation not permitted" way tar's direct extract does, since the
#       exec user doesn't own that mount point
extract_dir = "/tmp/restore-extract-#{Time.now.to_i}"
extract_script = "set -e; mkdir -p #{extract_dir} && tar -xzf /tmp/restore-files.tar.gz -C #{extract_dir} && cp -rf #{extract_dir}/. #{APP_DATA_PATH}/ && rm -rf #{extract_dir} /tmp/restore-files.tar.gz"
run!("kubectl exec -i -n #{NAMESPACE} #{WP_APP_POD} -- bash -c #{Shellwords.escape(extract_script)}", "[6/6] Extracting WordPress files into #{APP_DATA_PATH}")

# Local cleanup
FileUtils.rm_rf(unzip_dir)
File.delete(local_zip) rescue nil
run!("kubectl exec -i -n #{NAMESPACE} #{WP_MYSQL_POD} -- rm -f /tmp/restore-db.sql.gz", "Cleaning up DB dump inside MySQL pod")

# Post-restore pod health check — restore itself can succeed while still
# having knocked a pod over (OOM from the CPU/memory spike, etc.), so check
# restart counts before vs after rather than trusting exit codes alone.
sleep 5
app_restart_after   = pod_restart_count(NAMESPACE, WP_APP_POD)
mysql_restart_after = pod_restart_count(NAMESPACE, WP_MYSQL_POD)
app_phase            = pod_phase(NAMESPACE, WP_APP_POD)
mysql_phase          = pod_phase(NAMESPACE, WP_MYSQL_POD)

puts ""
puts "=== Post-restore pod check ==="
puts "WP_APP_POD   [#{WP_APP_POD}] phase=#{app_phase}   restarts #{app_restart_before.inspect} -> #{app_restart_after.inspect}"
puts "WP_MYSQL_POD [#{WP_MYSQL_POD}] phase=#{mysql_phase} restarts #{mysql_restart_before.inspect} -> #{mysql_restart_after.inspect}"

warned = false
if app_restart_before && app_restart_after && app_restart_after > app_restart_before
  puts "WARNING: WP_APP_POD restarted during restore (#{WP_APP_POD})"
  warned = true
end
if mysql_restart_before && mysql_restart_after && mysql_restart_after > mysql_restart_before
  puts "WARNING: WP_MYSQL_POD restarted during restore (#{WP_MYSQL_POD})"
  warned = true
end
if app_phase != 'Running'
  puts "WARNING: WP_APP_POD is not Running (phase=#{app_phase.inspect})"
  warned = true
end
if mysql_phase != 'Running'
  puts "WARNING: WP_MYSQL_POD is not Running (phase=#{mysql_phase.inspect})"
  warned = true
end

duration = (Time.now - start_time).round(1)
puts ""
if warned
  puts "=== Restore finished WITH WARNINGS (#{duration}s) — see above ==="
  exit 1
else
  puts "=== Restore completed successfully, no pod restarts detected (#{duration}s) ==="
end
