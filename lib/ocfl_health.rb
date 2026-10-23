# frozen_string_literal: true

require 'digest'
require 'json'
require 'pathname'
require 'rexml/document'
require 'time'

# Offline health checks for an Atlas OCFL storage pool. Plain Ruby and the
# standard library only, so it runs against a copy of the storage with no Atlas,
# Postgres or Solr — the situation docs/preservation.md is written for.
#
# Severity says what repair costs, which is what an operator has to decide on:
#   fatal       bytes are missing, corrupt or unreadable           (red)
#   repairable  the object breaks a rule, but nothing is lost       (yellow)
#   advisory    worth knowing, no action needed                     (green)
module OcflHealth
  SEVERITIES = %i[advisory repairable fatal].freeze

  Finding = Struct.new(:severity, :code, :message, :subject, keyword_init: true) do
    def to_h
      super.compact
    end
  end

  def self.grade(findings)
    return :red if findings.any? { |f| f.severity == :fatal }
    return :yellow if findings.any? { |f| f.severity == :repairable }

    :green
  end
end

require_relative 'ocfl_health/object_validator'
require_relative 'ocfl_health/envelope'
require_relative 'ocfl_health/mods_reading'
require_relative 'ocfl_health/pool'
require_relative 'ocfl_health/work_assessment'
require_relative 'ocfl_health/cli'
