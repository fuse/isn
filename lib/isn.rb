#!/usr/bin/env ruby

APP_PATH      = File.expand_path(File.join(File.dirname(__FILE__), '..'))
DATABASE_PATH = File.join(APP_PATH, 'db', 'isn.db')

require 'rubygems'
require 'bundler/setup'
require 'net/imap'
require 'grocer'
require 'active_record'
require 'sqlite3'

class Mailbox < ActiveRecord::Base
  validates :name, presence: true
end

def configuration
  @configuration ||= YAML.load File.open(File.join(APP_PATH, 'config', 'global.yml'))
end

def pusher
  @pusher ||= Grocer.pusher(
    certificate: File.join(APP_PATH, "certs", "certificate.pem"),
    gateway:     "gateway.sandbox.push.apple.com")
end

def notify(content, badge = 1)
  token         = configuration["global"]["notifications"]["token"]
  notification  = Grocer::Notification.new(
    device_token: token,
    alert:        content,
    badge:         badge,
    sound:        "siren.aiff")
  pusher.push(notification)
end

def process_mailboxes
  configuration["global"]["mailboxes"].each do |name, options|
    account = Net::IMAP.new(options["host"], :ssl => { :verify_mode => OpenSSL::SSL::VERIFY_NONE })
    account.login(options["login"], options["password"])

    skipped = options.has_key?('skip') ? options["skip"].split(',') : []
    account.list("", '*').each do |folder|
      next if skipped.include?(folder.name.downcase)

      full_name = "#{name}.#{folder.name}"

      account.select(folder.name)
      unread_messages = account.search(["NOT", "SEEN"])

      if unread_messages.any?
        mailbox       = Mailbox.find_or_create_by_name(full_name)
        existing_ids  = mailbox.messages_ids.split(',').map(&:to_i)
        ids           = unread_messages - existing_ids

        notify("#{ids.count} nouveaux mails dans #{folder.name}", ids.count) if ids.any?

        mailbox.update_attribute :messages_ids, unread_messages.join(',')
      end
    end
  end
end

def setup
  ActiveRecord::Base.establish_connection(
      adapter:  'sqlite3',
      database: DATABASE_PATH)

  unless File.exists?(DATABASE_PATH)
    ActiveRecord::Migration.create_table :mailboxes do |t|
      t.string  :name
      t.text    :messages_ids, :default => ""
    end
  end
end

setup
process_mailboxes