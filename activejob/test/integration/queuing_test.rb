# frozen_string_literal: true

require "helper"
require "jobs/logging_job"
require "jobs/hello_job"
require "jobs/provider_jid_job"
require "active_support/core_ext/numeric/time"

class QueuingTest < ActiveSupport::TestCase
  test "should run jobs enqueued on a listening queue" do
    TestJob.perform_later @id
    wait_for_jobs_to_finish_for(5.seconds)
    assert_job_executed
  end

  test "should not run jobs queued on a non-listening queue" do
    skip if adapter_is?(:inline, :async, :sucker_punch)
    old_queue = TestJob.queue_name

    begin
      TestJob.queue_as :some_other_queue
      TestJob.perform_later @id
      wait_for_jobs_to_finish_for(2.seconds)
      assert_job_not_executed
    ensure
      TestJob.queue_name = old_queue
    end
  end

  test "should supply a wrapped class name to Sidekiq" do
    skip unless adapter_is?(:sidekiq)
    Sidekiq::Testing.fake! do
      ::HelloJob.perform_later
      hash = ActiveJob::QueueAdapters::SidekiqAdapter::JobWrapper.jobs.first
      assert_equal "ActiveJob::QueueAdapters::SidekiqAdapter::JobWrapper", hash["class"]
      assert_equal "HelloJob", hash["wrapped"]
    end
  end

  test "should access provider_job_id inside Sidekiq job" do
    skip unless adapter_is?(:sidekiq)
    Sidekiq::Testing.inline! do
      job = ::ProviderJidJob.perform_later
      assert_equal "Provider Job ID: #{job.provider_job_id}", JobBuffer.last_value
    end
  end

  test "should supply a wrapped class name to DelayedJob" do
    skip unless adapter_is?(:delayed_job)
    ::HelloJob.perform_later
    job = Delayed::Job.first
    assert_match(/HelloJob \[[0-9a-f-]+\] from DelayedJob\(default\) with arguments: \[\]/, job.name)
  end

  test "resque JobWrapper should have instance variable queue" do
    skip unless adapter_is?(:resque)
    job = ::HelloJob.set(wait: 5.seconds).perform_later
    hash = Resque.decode(Resque.find_delayed_selection { true }[0])
    assert_equal hash["queue"], job.queue_name
  end

  test "should not run job enqueued in the future" do
    TestJob.set(wait: 10.minutes).perform_later @id
    wait_for_jobs_to_finish_for(5.seconds)
    assert_job_not_executed
  rescue NotImplementedError
    skip
  end

  test "should run job enqueued in the future at the specified time" do
    TestJob.set(wait: 5.seconds).perform_later @id
    wait_for_jobs_to_finish_for(2.seconds)
    assert_job_not_executed
    wait_for_jobs_to_finish_for(10.seconds)
    assert_job_executed
  rescue NotImplementedError
    skip
  end

  test "should supply a provider_job_id when available for immediate jobs" do
    skip unless adapter_is?(:async, :delayed_job, :sidekiq, :que, :queue_classic)
    test_job = TestJob.perform_later @id
    assert test_job.provider_job_id, "Provider job id should be set by provider"
  end

  test "should supply a provider_job_id when available for delayed jobs" do
    skip unless adapter_is?(:async, :delayed_job, :sidekiq, :que, :queue_classic)
    delayed_test_job = TestJob.set(wait: 1.minute).perform_later @id
    assert delayed_test_job.provider_job_id, "Provider job id should by set for delayed jobs by provider"
  end

  test "current locale is kept while running perform_later" do
    skip if adapter_is?(:inline)

    begin
      I18n.available_locales = [:en, :de]
      I18n.locale = :de

      TestJob.perform_later @id
      wait_for_jobs_to_finish_for(5.seconds)
      assert_job_executed
      assert_equal "de", job_executed_in_locale
    ensure
      I18n.available_locales = [:en]
      I18n.locale = :en
    end
  end

  test "current timezone is kept while running perform_later" do
    skip if adapter_is?(:inline)

    begin
      current_zone = Time.zone
      Time.zone = "Hawaii"

      TestJob.perform_later @id
      wait_for_jobs_to_finish_for(5.seconds)
      assert_job_executed
      assert_equal "Hawaii", job_executed_in_timezone
    ensure
      Time.zone = current_zone
    end
  end

  test "should run job with higher priority first" do
    skip unless adapter_is?(:delayed_job, :que)

    wait_until = Time.now + 3.seconds
    TestJob.set(wait_until: wait_until, priority: 20).perform_later "#{@id}.1"
    TestJob.set(wait_until: wait_until, priority: 10).perform_later "#{@id}.2"
    wait_for_jobs_to_finish_for(10.seconds)
    assert_job_executed "#{@id}.1"
    assert_job_executed "#{@id}.2"
    assert_job_executed_before("#{@id}.2", "#{@id}.1")
  end

  test "should run job with higher priority first in Backburner" do
    skip unless adapter_is?(:backburner)

    jobs_manager.tube.pause(3)
    TestJob.set(priority: 20).perform_later "#{@id}.1"
    TestJob.set(priority: 10).perform_later "#{@id}.2"
    wait_for_jobs_to_finish_for(10.seconds)
    assert_job_executed "#{@id}.1"
    assert_job_executed "#{@id}.2"
    assert_job_executed_before("#{@id}.2", "#{@id}.1")
  end

  private
    def assert_job_executed(id = @id)
      assert job_executed(id), "Job #{id} was not executed"
    end

    def assert_job_not_executed(id = @id)
      assert_not job_executed(id), "Job #{id} was executed"
    end

    def assert_job_executed_before(first_id, second_id)
      assert job_executed_at(first_id) < job_executed_at(second_id), "Job #{first_id} was not executed before Job #{second_id}"
    end
end
