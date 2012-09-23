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
  begin
    doc = agent.get(url)
  rescue Net::HTTPNotFound => e
    dputs "getUrlTitle error: #{e.message} for #{url}"
    return nil
  rescue Mechanize::ResponseCodeError => e
    dputs "getUrlTitle error: #{e.message} for #{url}"
    return nil
  rescue OpenSSL::SSL::SSLError => e
    dputs "getUrlTitle error: #{e.message} for #{url}"
    return ""
  rescue SocketError => e
    dputs "getUrlTitle error: #{e.message} for #{url}"
    return nil # sorry...
  rescue Mechanize::UnsupportedSchemeError => e
    ["http://", "https://", "ftp://", "ftps://", "mailto://", "nntp://", "xmpp://"].each do |format|
      if url.include? format
        return "" # valid format
      end
    end
    dputs "getUrlTitle error: #{e.message} for #{url}"
    return nil # nope
  rescue Errno::ETIMEDOUT => e
  rescue Net::HTTP::Persistent::Error => e
    dputs "getUrlTitle error: #{e.message} for #{url}"
    return nil
  rescue Errno::EHOSTUNREACH => e
  rescue Errno::ENETUNREACH => e
    dputs "getUrlTitle error: #{e.message} for #{url}"
    return nil
  rescue Mechanize::RedirectLimitReachedError => e
    dputs "getUrlTitle error: #{e.message} for #{url}"
    return nil
  rescue URI::InvalidURIError => e
    dputs "getUrlTitle error: #{e.message} for #{url}"
    return nil
  end
  if doc
    begin
      return (doc.title.nil? ? "" : doc.title)
    rescue => e
      dputs "getUrlTitle 'doc' error: #{e.message} for #{url}"
      return ""
    end
  end
  dputs "getUrlTitle, no doc, no title, wtf ? #{url}"
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

def userExcluded(user)
  @config['exclude_users'].include? user
end

def cleanTags(tags)
  t = []
  tags.map {|tt| t << tt.strip.gsub("#", "")}
  t
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
  @no_urls = true

  l = File.open(file, 'r')
  l.each do |line|
    line.encode!('UTF-8', 'UTF-8', :invalid => :replace)
    local_urls = []
    # 1/ extract urls
    urls = URI.extract(line)
    urls.each do |url|
      if url =~ /^(http|gopher|mailto|ftp)/
        local_urls << url
      end
    end
    next if local_urls.empty?
    # 2/ extract user and timestamp
    things = line.match(/^(\d{4}-\d{2}-\d{2}\w\d{2}:\d{2}:\d{2})\s+<(.*)>\s/i)
    user = things[2] if things
    timestamp = things[1] if things
    next if userExcluded(user) # excluded users, like lapool bot
    # 3/ extract tags
    tags = line.match(/^.*\#(.*),?\#$/)
    if tags
      tags = tags[1]
      tags = tags.split(",")
    else
      tags = []
    end
    next if (tags.empty? and @config['exclude_no_tags'])
    tags = cleanTags(tags)
    next if urlHasTagExcluded(tags)
    # 4/ fill @urls with the new urls
    urls_w_title = []
    local_urls.each do |url|
      next if urlInCrapList(url)
      valid = false
      title = getUrlTitle(url)  # also used to verify if the url is valid (no 404)
      # title is nil (fail), "" (no title, image), or a non empty string
      if title.nil?
        dputs "URL ignored #{url} return code is a 404 or other than 200 title '#{title}'"
      end
      if !title.nil?
        title.gsub!("\n", "")
        title.gsub!("\r", "")
      end

      valid = true if !title.nil?

      begin
        url = PostRank::URI.clean(url)
      rescue Addressable::URI::InvalidURIError
	valid = false
      end

      dputs "#{valid ? 'valid' : 'invalid'} url '#{url}' w/ title '#{title}' tags: '#{tags}'"

      urls_w_title << {:url => url, :title => title} if valid
      if valid
        dputs "URL found : '#{url}'"
        dputs "User: '#{user}', tags : #{tags.join(', ')}"
      end
    end
    tags = fixTagsWithSynonyms(tags)
    @urls << {:log => log, :user => user, :tags => tags, :urls => urls_w_title} if !urls_w_title.empty?
    @no_urls = false
  end
    
  addLogToVarAndSave(log) if @no_urls
  dputs "Log with no urls :(" if @no_urls

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

