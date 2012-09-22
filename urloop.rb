#!/usr/bin/env ruby
# coding: utf-8
require 'rubygems'
require 'bundler/setup'

Bundler.require
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
begin
  @craplist = YAML.load_file('crap.yml')
rescue Errno::ENOENT
  puts "Please create a crap.yml file, even empty."
  exit 1
end

# Synonyms
begin
  @synonyms = YAML.load_file('synonyms.yml')
rescue Errno::ENOENT
  puts "synonyms.yml : Why removing this innocent file ?"
  exit 1
end

# already parsed logs list
begin
  @already_parsed_logs = YAML.load_file('logs_parsed.yml')
rescue Errno::ENOENT
  File.open('logs_parsed.yml', 'w') {|file| file.puts([].to_yaml)}
  @already_parsed_logs = YAML.load_file('logs_parsed.yml')
end

# lazy debug puts
def dputs(msg)
  puts "[DEBUG] #{msg}" if @config['debug']
end

dputs "URloop version #{VERSION} - Debug true"

trap("INT") { itsAtrap("int") }

dputs "Now trap'ing: INT"

# Connect to the SemanticScuttle/Delicious API
d = WWW::Delicious.new(@config['api']['user'], @config['api']['pass'], :base_uri => @config['api']['url'])
begin
  d.valid_account?
  dputs "[API] Valid account"
rescue WWW::Delicious::ResponseError
  # ignore
end

def itsAtrap(trapsig)
  case trapsig
  when 'int'
    trapIntSaveParsedLogs
  else
    trapIntSaveParsedLogs
  end
end

def trapIntSaveParsedLogs
  puts "Got trapped by a INT signal, going to save the parsed logs file and exit nicely."
  File.open('logs_parsed.yml', 'w') {|file| file.puts(@already_parsed_logs.to_yaml)}
  exit 0
end

def getUrlTitle(url)
  agent = Mechanize.new
  agent.user_agent_alias = 'Mac Safari'
  doc = agent.get(url)
  if doc
    return doc.title || ""
  end
  return ""
end

def addLogToVarAndSave(logname)
  @already_parsed_logs << logname
  File.open('logs_parsed.yml', 'w') {|file| file.puts(@already_parsed_logs.to_yaml)}
end

def urlInCrapList(url)
  @craplist.each do |urlcrap|
    if url.include? urlcrap
      return true
    end
  end
  return false
end

def urlHasTagExcluded(tags)
  @config['exclude_tags'].each do |tag|
    if tags.include? tag
      return true
    end
  end
  return false
end

def fixTagsWithSynonyms(tags)
  @fixed_tags = []
  tags.each do |tag|
    t = nil
    @synonyms.each_pair do |key, vals|
      if vals.include? tag
        t = key
      end
    end
    @fixed_tags << (t || tag)
  end
  return @fixed_tags
end

def askUserYesOrNot(question)
  while true
    print question
    case gets.strip
    when 'Y', 'y', 'yes'
      return true
    when /\A[nN]o?\Z/
      break
    end
  end
  return false
end

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
    urls_w_title = []
    local_urls.each do |url|
      valid = false
      title = nil
      begin
        title = getUrlTitle(url)  # also used to verify if the url is valid (no 404)
      rescue Mechanize::ResponseCodeError
        dputs "URL ignored #{url} return code is a 404 or other than 200"
      end
      if !title.nil?
        title.gsub!("\n", "")
        title.gsub!("\r", "")
      end

      valid = true if (!urlInCrapList(url) && !urlHasTagExcluded(tags) && title)
      valid = false if (tags.empty? and @config['exclude_no_tags'])

      url = PostRank::URI.clean(url)
      urls_w_title << {:url => url, :title => title} if valid
    end
    tags = fixTagsWithSynonyms(tags)
    @urls << {:log => log, :user => user, :tags => tags, :urls => urls_w_title} if !urls_w_title.empty?
  end

  dputs ""
  l.close
end

# start working with the user
pp @urls

@old_log = nil

# log: logname
# user: foo
# tags: foo, bar, baz
# urls:
#   url: foobar
#   title: coin

@urls.each do |urls|
  if @old_log != urls[:log]
    # new log to pase, save the old one in the parsed files
    addLogToVarAndSave(@old_log)

    urls[:urls].each do |url|
      # Show the url, with tag, and user to the user
      puts ">>> #{urls[:user]} posted #{url[:url]} with tags #{urls[:tags].join(", ")}"
      puts ">> Title: #{url[:title]}"
      # Ask if we upload it
      ret = askUserYesOrNot("Post this URL to the remote API ? (if no you will need to upload manually) [y/n]: ")
      if ret
        # Adding post to scuttle, replacing if already exists
        post = d.posts_get(:url => url[:url])
        newpost = d.posts_add(:url => url[:url], :title => url[:title], :tags => urls[:tags], :replace => true)
        if newpost
          puts "=> Post saved !"
        else
          puts "=> Unsaved, error somewhere :("
        end
      else
        next # dont save, switch to next url
      end
    end

  end
  @old_log = urls[:log]
end
addLogToVarAndSave(@old_log) # the last one

