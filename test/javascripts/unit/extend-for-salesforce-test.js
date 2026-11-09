import { module, test } from "qunit";
import { updateSalesforcePersonFields } from "discourse/plugins/discourse-salesforce/discourse/initializers/extend-for-salesforce";

module("Unit | Initializer | extend-for-salesforce", function () {
  test("updates Salesforce user custom fields on matching loaded posts", function (assert) {
    const topic = {
      postStream: {
        posts: [
          { user_id: 1, user_custom_fields: { existing: "value" } },
          { user_id: 2, user_custom_fields: { other: "value" } },
          { user_id: 1 },
        ],
      },
    };

    updateSalesforcePersonFields(topic, {
      user_id: 1,
      field: "salesforce_contact_id",
      value: "003123",
    });

    assert.deepEqual(
      topic.postStream.posts.map((post) => post.user_custom_fields),
      [
        { existing: "value", salesforce_contact_id: "003123" },
        { other: "value" },
        { salesforce_contact_id: "003123" },
      ]
    );
  });

  test("clears only the confirmed Contact across the author's loaded posts", function (assert) {
    const topic = {
      postStream: {
        posts: [
          {
            user_id: 1,
            user_custom_fields: {
              salesforce_contact_id: "old",
              salesforce_lead_id: "lead",
            },
          },
          {
            user_id: 2,
            user_custom_fields: { salesforce_contact_id: "other" },
          },
          {
            user_id: 1,
            user_custom_fields: {
              salesforce_contact_id: "old",
              existing: "value",
            },
          },
          {
            user_id: 1,
            user_custom_fields: { salesforce_contact_id: "new" },
          },
        ],
      },
    };

    updateSalesforcePersonFields(topic, {
      user_id: 1,
      field: "salesforce_contact_id",
      value: null,
      expected_value: "old",
    });

    assert.deepEqual(
      topic.postStream.posts.map((post) => post.user_custom_fields),
      [
        { salesforce_contact_id: null, salesforce_lead_id: "lead" },
        { salesforce_contact_id: "other" },
        { salesforce_contact_id: null, existing: "value" },
        { salesforce_contact_id: "new" },
      ],
      "The update preserves other authors, fields, and newer Contact associations"
    );
  });
});
