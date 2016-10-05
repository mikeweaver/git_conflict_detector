module ErrorsJson
  extend ActiveSupport::Concern

  included do
    fields do
      errors_json :string, limit: 256, required: false
      ignore_errors :boolean, default: false, required: true
    end

    scope :unignored_errors, lambda { where('errors_json IS NOT NULL').where(ignore_errors: false) }

    def error_list
      @error_list ||= JSON.parse(self.errors_json || '[]')
    end

    def error_list=(list)
      # clear the ignore_errors flag if the errors change
      if list.empty?
        self.errors_json = nil
        @error_list = []
        self.ignore_errors = false
      elsif error_list != list
        self.errors_json = list.to_json
        @error_list = list
        self.ignore_errors = false
      end
    end

    def self.get_error_counts(error_json_objects)
      error_counts = {}
      error_json_objects.each do |error_json_object|
        error_json_object.error_list.each do |error|
          error_counts[error] = error_counts[error].to_i + 1
        end
      end
      error_counts
    end

    def reload
      super
      # clear memoized data on reload
      @error_list = nil
    end
  end
end
