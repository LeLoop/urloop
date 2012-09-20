#!/usr/bin/env ruby
# coding: utf-8
require "rubygems"
require "uri"
require "yaml"
require "pp"

VERSION=0.1

# Config
begin
  @config = YAML.load_file('config.yml')
rescue Errno::ENOENT
  puts "Please create a config.yml file."
  exit 1
end

# Scraplist
# Synonyms

# already parsed logs list
begin
  @already_parsed_logs = YAML.load_file('logs_parsed.yml')
rescue Errno::ENOENT
  @already_parsed_logs = []
end

# lazy debug puts
def dputs(msg)
  puts "[DEBUG] #{msg}" if @config['debug']
end

dputs "URloop version #{VERSION} - Debug true"

# scan for logs to parse : config['logs_dir']
# scan directory, and exclude logs which filename is in the already_parsed logs files
# also exclude the log-of-the-day from being parsed
@logs_to_scan = []
@log_of_the_day = Time.now.strftime @config['logs']['format']
Dir.new(@config['logs']['dir']).find_all.each do |log|
  if @already_parsed_logs.include?(log) or @log_of_the_day == log or ['..', '.'].include? log
    next
  else
    @logs_to_scan << log
  end
end

dputs "Logs to scan: #{@logs_to_scan.join(', ')}"

# parse logs and grab urls
@urls = []

@logs_to_scan.each do |log|
  file = File.join(@config['logs']['dir'], log)
  next if !File.readable?(file) or !File.exists?(file)
  dputs "Parsing #{file}"

  l = File.open(file, 'r')
  l.each do |line|
    local_urls = []
    # 1/ extract urls
    urls = URI.extract(line)
    urls.each do |url|
      if url =~ /^(http|gopher|mailto|ftp)/
        local_urls << url
      end
    end
    next if local_urls.empty?
    dputs "URLs found : #{local_urls.join(", ")}"
    # 2/ extract user
    user = line.match(/  <(.*)>/)
    user = user[1] if user
    # 3/ extract tags
    tags = line.match(/#(.*),?#/)
    if tags
      tags = tags[1]
      tags = tags.split(",")
    else
      tags = []
    end
    # 4/ fill @urls with the new urls
    dputs "User: #{user}, tags : #{tags.join(', ')}"
    @urls << {:user => user, :tags => tags, :urls => local_urls}
  end

  dputs ""
  l.close
end

# start working with the user
pp @urls
