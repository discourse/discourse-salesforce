# frozen_string_literal: true

require_relative "../spec_helper"

RSpec.describe Salesforce::Person do
  describe ".email_verified?" do
    it "preserves core verification rules without queries when associations are preloaded" do
      confirmed = Fabricate(:user)
      confirmed.activate
      unconfirmed = Fabricate(:user)
      no_tokens = Fabricate(:user)
      no_tokens.email_tokens.delete_all
      sso = Fabricate(:user)
      Fabricate(:single_sign_on_record, user: sso, external_email: sso.email.upcase)
      different_email = Fabricate(:user)
      different_email.email_tokens.delete_all
      Fabricate(:email_token, user: different_email, email: "previous@example.com", confirmed: true)
      staged = Fabricate(:user, staged: true)
      ids = [confirmed, unconfirmed, no_tokens, sso, different_email, staged].map(&:id)
      expected =
        User
          .where(id: ids)
          .to_h { |user| [user.id, user.active? && !user.staged? && user.email_confirmed?] }
      users =
        User.where(id: ids).includes(:primary_email, :email_tokens, :single_sign_on_record).to_a
      verified = nil

      queries =
        track_sql_queries do
          verified = users.to_h { |user| [user.id, described_class.email_verified?(user)] }
        end

      expect(verified).to eq(expected)
      expect(verified.values_at(*ids)).to eq([true, false, true, true, false, false])
      expect(queries).to be_empty
    end
  end
end
