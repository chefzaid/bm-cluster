#!/usr/bin/env ruby
require 'sidekiq'
require 'sidekiq/cron/poller'
require 'minitest/autorun'
require_relative '/opt/gitlab/embedded/service/gitlab-rails/lib/gitlab/patch/sidekiq_cron_poller'

module Gitlab
  class << self
    attr_accessor :config
  end
end

class PollerCompatibilityTest < Minitest::Test
  def setup
    Gitlab.config = Struct.new(:cron_jobs).new(Struct.new(:poll_interval).new(nil))
    @poller = Class.new(Sidekiq::Cron::Poller) do
      prepend Gitlab::Patch::SidekiqCronPoller
    end.allocate
    @settings = { average_scheduled_poll_interval: 15 }
    @poller.instance_variable_set(:@config, @settings)
  end

  def test_explicit_gitlab_interval_wins
    Gitlab.config.cron_jobs.poll_interval = 12
    @settings[:poll_interval_average] = 20
    assert_equal 12, @poller.send(:poll_interval_average, 4)
  end

  def test_sidekiq_interval_when_gitlab_interval_is_unset
    @settings[:poll_interval_average] = 20
    assert_equal 20, @poller.send(:poll_interval_average, 4)
  end

  def test_scaled_interval_when_neither_is_configured
    assert_equal 60, @poller.send(:poll_interval_average, 4)
  end

  def test_new_cron_process_count_option
    @settings[:cron_poll_process_count] = 2
    count = @poller.send(:process_count)
    assert_equal 2, count
    assert_equal 30, @poller.send(:poll_interval_average, count)
  end
end
