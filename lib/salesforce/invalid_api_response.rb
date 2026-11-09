# frozen_string_literal: true

module ::Salesforce
  class InvalidApiResponse < ::StandardError
    attr_reader :status

    def initialize(message = nil, status: nil)
      super(message)
      @status = status
    end
  end
end
