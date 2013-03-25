require 'abstract_unit'
require 'active_support/queueing'

class SynchronousQueueTest < ActiveSupport::TestCase
  class Job
    class << self
      attr_accessor :ran
    end
    def run
      self.class.ran = true
    end
  end

  class ExceptionRaisingJob
    def run; raise end
  end

  def setup
    @queue = ActiveSupport::SynchronousQueue.new
  end

  def test_runs_jobs_immediately
    job = Job.new
    @queue.push job
    assert Job.ran

    assert_raises RuntimeError do
      @queue.push ExceptionRaisingJob.new
    end
  end
end
