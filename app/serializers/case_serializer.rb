# frozen_string_literal: true

class Salesforce::CaseSerializer < ApplicationSerializer
  attributes :id, :uid, :number, :status
end
