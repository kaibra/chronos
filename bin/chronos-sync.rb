#!/usr/bin/ruby

require 'optparse'
require 'ostruct'
require 'json'
require 'open-uri'
require 'fileutils'
require 'net/http'
require 'time'
require 'yaml'
require 'set'

options = OpenStruct.new
options.update_from_chronos = false
options.force = false

opts = OptionParser.new do |o|
  o.banner = "Usage: #{$0} [options]"
  o.on("-u", "--uri URI", "URI for Chronos") do |t|
    options.uri = /^\/*(.*)/.match(t.reverse)[1].reverse
  end
  o.on("-p", "--config PATH", "Path to configuration") do |t|
    options.config_path = t
  end
  o.on("-c", "--update-from-chronos", "Update local job configuration from Chronos") do |t|
    options.update_from_chronos = true
  end
  o.on("-f", "--force", "Forcefully update data in Chronos from local configuration") do |t|
    options.force = true
  end
end

begin
  opts.parse(ARGV)
  raise OptionParser::MissingArgument if options.uri.nil?
  raise OptionParser::MissingArgument if options.config_path.nil?
rescue OptionParser::InvalidOption, OptionParser::MissingArgument
  $stderr.puts $!.to_s
  $stderr.puts opts
  abort
end

json = nil
open("#{options.uri}/scheduler/jobs") do |f|
  data = f.readlines()
  json = JSON.parse(data.first)
end

def strip_job(job)
  newjob = job.dup
  newjob.delete 'successCount'
  newjob.delete 'errorCount'
  newjob.delete 'lastSuccess'
  newjob.delete 'lastError'
  newjob.delete 'epsilon'
  newjob.delete 'async'
  newjob.delete 'retries'
  newjob.delete 'executor'
  newjob.delete 'executorFlags'
  newjob
end

def sanitize_name(name)
  r = name.dup
  r.gsub!(/^.*(\\|\/)/, '')
  r.gsub!(/[^0-9A-Za-z.\-]/, '_')
  r
end

scheduled_jobs = {}
dependent_jobs = {}

json.each do |j|
  stripped_job = strip_job(j)
  if j.include? 'schedule'
    scheduled_jobs[j['name']] = stripped_job
  else
    dependent_jobs[j['name']] = stripped_job
  end
end

def write_job(f, job)
  f.puts "## This file was automatically generated by `#{$0}`."
  f.puts "## If you edit it, please remove these lines as a courtesy."
  f.puts "#"
  f.puts "# Chronos configuration for `#{job['name']}`"
  f.puts "#"
  f.puts "# For details on Chronos configuration, see:"
  f.puts "#  https://github.com/airbnb/chronos/blob/master/README.md#job-configuration"
  f.puts "#"
  f.puts YAML.dump(job)
end

if options.update_from_chronos
  Dir.chdir(options.config_path) do
    FileUtils.mkdir_p('dependent')
    Dir.chdir('dependent') do
      dependent_jobs.each do |name,job|
        File.open("#{sanitize_name(name)}.yaml", 'w') do |f|
          write_job(f, job)
        end
      end
    end

    FileUtils.mkdir_p('scheduled')
    Dir.chdir('scheduled') do
      scheduled_jobs.each do |name,job|
        File.open("#{sanitize_name(name)}.yaml", 'w') do |f|
          write_job(f, job)
        end
      end
    end
  end
  exit 0
end

jobs = {}
Dir.chdir(options.config_path) do
  Dir.chdir('dependent') do
    Dir.glob('*.yaml') do |fn|
      lines = File.open(fn).readlines().join
      begin
        parsed = YAML.load(lines)
        jobs[parsed['name']] = parsed
        if fn.gsub(/\.yaml$/, '') != sanitize_name(parsed['name'].gsub(/\.yaml$/, ''))
          puts "Name from #{fn} doesn't match job name"
        end
        if parsed.include? 'schedule'
          puts "Scheduled job from #{fn} must not contain a schedule!"
        end
      rescue Psych::SyntaxError => e
        $stderr.puts "Parsing error when reading dependent/#{fn}"
      end
    end
  end

  Dir.chdir('scheduled') do
    Dir.glob('*.yaml') do |fn|
      lines = File.open(fn).readlines().join
      begin
        parsed = YAML.load(lines)
        jobs[parsed['name']] = parsed
        if fn.gsub(/\.yaml$/, '') != sanitize_name(parsed['name'].gsub(/\.yaml$/, ''))
          puts "Name from #{fn} doesn't match job name"
        end
        if parsed.include? 'parents'
          puts "Scheduled job from #{fn} must not contain parents!"
        end
      rescue Psych::SyntaxError => e
        $stderr.puts "Parsing error when reading scheduled/#{fn}"
      end
    end
  end
end

jobs_to_be_updated = []

# Update scheduled jobs first
jobs.each do |name,job|
  if job.include? 'schedule'
    if scheduled_jobs.include? name
      existing_job = scheduled_jobs[name]
      new_job = job
      # Caveat: when comparing scheduled jobs, we have to ignore part of the
      # schedule field because it gets updated by chronos.
      existing_job['schedule'] = existing_job['schedule'].gsub(/^R\d*\/[^\/]+\//, '')
      new_schedule = new_job['schedule']
      new_job['schedule'] = new_job['schedule'].gsub(/^R\d*\/[^\/]+\//, '')
      if options.force || !scheduled_jobs.include?(name) || existing_job.to_s != new_job.to_s
        new_job['schedule'] = new_schedule
        jobs_to_be_updated << {
          :new => job,
          :old => scheduled_jobs[name],
        }
      end
    else
      jobs_to_be_updated << {
        :new => job,
        :old => nil,
      }
    end
  end
end

# The order for updating dependent jobs matters.
dependent_jobs_to_be_updated = []
dependent_jobs_to_be_updated_set = Set.new
jobs.each do |name,job|
  if job.include? 'parents'
    if dependent_jobs.include? name
      existing_job = dependent_jobs[name]
      new_job = job
      if options.force || !dependent_jobs.include?(name) || existing_job.to_s != new_job.to_s
        dependent_jobs_to_be_updated_set.add(job['name'])
        dependent_jobs_to_be_updated << {
          :new => job,
          :old => dependent_jobs[name],
        }
      end
    else
      dependent_jobs_to_be_updated << {
        :new => job,
        :old => nil,
      }
    end
  end
end

# TODO: detect circular dependencies more intelligently
remaining_attempts = 100
while !dependent_jobs_to_be_updated.empty? && remaining_attempts > 0
  remaining_attempts -= 1
  these_jobs = dependent_jobs_to_be_updated.dup
  to_delete = []
  these_jobs.each_index do |idx|
    job = these_jobs[idx][:new]
    parents = job['parents']
    # Add only the jobs for which their parents have already been added.
    can_be_added = true
    parents.each do |p|
      if dependent_jobs_to_be_updated_set.include?(p)
        # This job can't be added yet.
        can_be_added = false
      end
    end
    if can_be_added
      jobs_to_be_updated << these_jobs[idx]
      to_delete << idx
      dependent_jobs_to_be_updated_set.delete(job['name'])
    end
  end
  to_delete = to_delete.sort.reverse
  to_delete.each do |idx|
    dependent_jobs_to_be_updated.delete_at idx
  end
end

if !dependent_jobs_to_be_updated.empty?
  jobs_to_be_updated += dependent_jobs_to_be_updated
end

if !jobs_to_be_updated.empty?
  puts "These jobs will be updated:"
end

jobs_to_be_updated.each do |j|
  puts "About to update #{j[:new]['name']}"
  puts
  puts "Old job:", YAML.dump(j[:old])
  puts
  puts "New job:", YAML.dump(j[:new])
  puts
end

jobs_to_be_updated.each do |j|
  job = j[:new]
  method = nil
  if job.include? 'schedule'
    method = 'iso8601'
  else
    method = 'dependency'
  end
  uri = URI("#{options.uri}/scheduler/#{method}")
  req = Net::HTTP::Put.new(uri.request_uri)
  req.body = JSON.generate(job)
  req.content_type = 'application/json'

  puts "Sending PUT for `#{job['name']}` to #{uri.request_uri}"

  begin
    res = Net::HTTP.start(uri.hostname, port: uri.port, use_ssl: (uri.port == 443)) do |http|
      http.request(req)
    end

    case res
    when Net::HTTPSuccess, Net::HTTPRedirection
      # OK
    end
  rescue Timeout::Error, Errno::EINVAL, Errno::ECONNRESET, EOFError,
    Net::HTTPBadResponse, Net::HTTPHeaderSyntaxError, Net::ProtocolError => e
    $stderr.puts "Error updating job #{job['name']}!"
    $stderr.puts res.value
  end

  # Pause after each request so we don't explode chronos
  sleep 0.1
end

puts "Finished checking/updating jobs"
puts

# Look for jobs in chronos which don't exist here, print a warning
def check_if_defined(jobs, name)
  if !jobs.include?(name)
    $stderr.puts "The job #{name} exists in chronos, but is not defined!"
  end
end

dependent_jobs.each do |name, job|
  check_if_defined(jobs, name)
end

scheduled_jobs.each do |name, job|
  check_if_defined(jobs, name)
end
