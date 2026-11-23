# frozen_string_literal: true

module DiscourseCrm
  class FailureReason
    CODES = {}.freeze
    EXCEPTIONS = {}.freeze
    COMMON_EXCEPTIONS = {
      "Discourse::InvalidParameters" => "configuration",
      "Faraday::TimeoutError" => "timeout",
      "Timeout::Error" => "timeout",
      "Faraday::ConnectionFailed" => "connection",
    }.freeze
    HTTP_ERRORS = {
      400 => "validation",
      401 => "authentication",
      403 => "permissions",
      404 => "not_found",
      429 => "rate_limit",
    }.freeze

    def self.for(attempt)
      provider = SyncConfiguration::PROVIDERS[attempt.provider]
      formatter = provider.respond_to?(:failure_reason_class) ? provider.failure_reason_class : self
      formatter.new(attempt).message
    end

    def initialize(attempt)
      @attempt = attempt
      @diagnostics = attempt.diagnostics || {}
    end

    def message
      codes = identifiers("codes")
      keys = codes.filter_map { |code| self.class::CODES[code] }
      return translate("provider_code", code: codes.join(", ")) if codes.any? && keys.empty?
      if keys.empty?
        keys = identifiers("category").filter_map { |category| self.class::CODES[category] }
      end
      return keys.uniq.map { |key| translate(key) }.join(" ") if keys.any?

      translate(fallback)
    end

    private

    attr_reader :attempt, :diagnostics

    def identifiers(key)
      SyncAttempt.diagnostic_identifiers(diagnostics[key])
    end

    def fallback
      status = diagnostics["status"]
      self.class::EXCEPTIONS[attempt.error_class] || COMMON_EXCEPTIONS[attempt.error_class] ||
        HTTP_ERRORS[status] || (status.is_a?(Integer) && status >= 500 ? "temporary" : "unknown")
    end

    def translate(key, **options)
      I18n.t("discourse_crm.sync_activity.errors.#{key}", **options)
    end
  end
end
