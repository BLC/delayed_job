require 'mongo_mapper'

MongoMapper::Document.class_eval do
  yaml_as "tag:ruby.yaml.org,2002:MongoMapper"
  
  def self.yaml_new(klass, tag, val)
    klass.find(val['_id'])
  end

  def to_yaml_properties
    ['@_id']
  end
end

module Delayed
  module Backend
    module MongoMapper
      class Job
        include ::MongoMapper::Document
        include Delayed::Backend::Base
        set_collection_name 'delayed_jobs'
        
        key :priority,    Integer, :default => 0
        key :attempts,    Integer, :default => 0
        key :handler,     String, :index => true # For looking up duplicates
        key :run_at,      Time
        key :locked_at,   Time
        key :locked_by,   String, :index => true
        key :failed_at,   Time
        key :last_error,  String
        timestamps!
        
        before_save :set_default_run_at

        ensure_index [[:priority, 1], [:run_at, 1]]
        
        def self.before_fork
          ::MongoMapper.connection.close
        end
        
        def self.after_fork
          ::MongoMapper.connect(RAILS_ENV)
        end
        
        def self.db_time_now
          Time.now.utc
        end
        
        def self.find_available(worker_name, limit = 5, max_run_time = Worker.max_run_time)
          right_now = db_time_now

          conditions = {
            :run_at.lte => right_now,
            :failed_at => nil,
            :limit => -limit, # In mongo, positive limits are 'soft' and negative are 'hard'
            :sort => [['priority', 1], ['run_at', 1]]
          }
          
          (conditions[:priority] ||= {})['$gte'] = Worker.min_priority.to_i if Worker.min_priority
          (conditions[:priority] ||= {})['$lte'] = Worker.max_priority.to_i if Worker.max_priority

          # Nested "$or"s arent't supported yet, so let's do this in two passes still
          results = all(conditions.merge("$or" => [{:locked_at => nil}, {:locked_at => {"$lt" => right_now - max_run_time}}]))
          results += all(conditions.merge({:locked_by => worker_name})) if results.size < limit
          results
        end
        
        # When a worker is exiting, make sure we don't have any locked jobs.
        def self.clear_locks!(worker_name)
          collection.update({:locked_by => worker_name}, {"$set" => {:locked_at => nil, :locked_by => nil}}, :multi => true)
        end
        
        # Lock this job for this worker.
        # Returns true if we have the lock, false otherwise.
        def lock_exclusively!(max_run_time, worker = worker_name)
          right_now = self.class.db_time_now
          overtime = right_now - max_run_time.to_i
          
          conditions = {:_id => id, :run_at => {"$lte" => right_now}, "$or" => [{:locked_at => nil}, 
                                                                                {:locked_at => {"$lt" => overtime}},
                                                                                {:locked_by => worker}]} 

          collection.update(conditions, {"$set" => {:locked_at => right_now, :locked_by => worker}})
          affected_rows = collection.find({:_id => id, :locked_by => worker}).count
          if affected_rows == 1
            self.locked_at = right_now
            self.locked_by = worker
            return true
          else
            return false
          end
        end
      end
    end
  end
end
