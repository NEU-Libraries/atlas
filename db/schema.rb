# This file is auto-generated from the current state of the database. Instead
# of editing this file, please use the migrations feature of Active Record to
# incrementally modify your database, and then regenerate this schema definition.
#
# This file is the source Rails uses to define your schema when running `bin/rails
# db:schema:load`. When creating a new database, `bin/rails db:schema:load` tends to
# be faster and is potentially less error prone than running all of your
# migrations from scratch. Old migrations may fail to apply correctly if those
# migrations use external dependencies or application code.
#
# It's strongly recommended that you check this file into your version control system.

ActiveRecord::Schema[7.0].define(version: 2026_07_10_120000) do
  # These are extensions that must be enabled in order to support this database
  enable_extension "plpgsql"
  enable_extension "uuid-ossp"

  create_table "audit_events", force: :cascade do |t|
    t.string "actor_nuid", null: false
    t.string "on_behalf_of_nuid"
    t.string "action", null: false
    t.string "change_type", null: false
    t.datetime "occurred_at", null: false
    t.string "event_source", null: false
    t.jsonb "payload", default: {}, null: false
    t.text "note"
    t.string "resource_id"
    t.string "resource_type"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["actor_nuid"], name: "index_audit_events_on_actor_nuid"
    t.index ["occurred_at"], name: "index_audit_events_on_occurred_at"
    t.index ["on_behalf_of_nuid"], name: "index_audit_events_on_on_behalf_of_nuid"
    t.index ["resource_id", "occurred_at"], name: "index_audit_events_on_resource_id_and_occurred_at", order: { occurred_at: :desc }
    t.index ["resource_id", "resource_type"], name: "index_audit_events_on_resource_id_and_resource_type"
  end

  create_table "compilation_collection_inclusions", force: :cascade do |t|
    t.bigint "compilation_id", null: false
    t.string "resource_noid", null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["compilation_id", "resource_noid"], name: "idx_compilation_collection_inclusions_uniq", unique: true
    t.index ["compilation_id"], name: "index_compilation_collection_inclusions_on_compilation_id"
    t.index ["resource_noid"], name: "index_compilation_collection_inclusions_on_resource_noid"
  end

  create_table "compilation_exclusions", force: :cascade do |t|
    t.bigint "compilation_id", null: false
    t.string "resource_noid", null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["compilation_id", "resource_noid"], name: "idx_compilation_exclusions_uniq", unique: true
    t.index ["compilation_id"], name: "index_compilation_exclusions_on_compilation_id"
    t.index ["resource_noid"], name: "index_compilation_exclusions_on_resource_noid"
  end

  create_table "compilation_work_inclusions", force: :cascade do |t|
    t.bigint "compilation_id", null: false
    t.string "resource_noid", null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["compilation_id", "resource_noid"], name: "idx_compilation_work_inclusions_uniq", unique: true
    t.index ["compilation_id"], name: "index_compilation_work_inclusions_on_compilation_id"
    t.index ["resource_noid"], name: "index_compilation_work_inclusions_on_resource_noid"
  end

  create_table "compilations", force: :cascade do |t|
    t.string "noid", null: false
    t.string "title", null: false
    t.text "description"
    t.string "depositor", null: false
    t.string "edit_users", default: [], null: false, array: true
    t.string "read_groups", default: [], null: false, array: true
    t.string "edit_groups", default: [], null: false, array: true
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["depositor"], name: "index_compilations_on_depositor"
    t.index ["noid"], name: "index_compilations_on_noid", unique: true
  end

  create_table "idempotency_keys", force: :cascade do |t|
    t.bigint "user_id", null: false
    t.string "key", null: false
    t.string "resource_type", null: false
    t.string "resource_noid", null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["user_id", "key"], name: "index_idempotency_keys_on_user_id_and_key", unique: true
    t.index ["user_id"], name: "index_idempotency_keys_on_user_id"
  end

  create_table "metadata_mets", force: :cascade do |t|
    t.jsonb "json_attributes"
    t.string "valkyrie_id"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
  end

  create_table "metadata_mods", force: :cascade do |t|
    t.jsonb "json_attributes"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.string "valkyrie_id"
  end

  create_table "minter_states", id: :serial, force: :cascade do |t|
    t.string "namespace", default: "default", null: false
    t.string "template", null: false
    t.text "counters"
    t.bigint "seq", default: 0
    t.binary "rand"
    t.datetime "created_at", precision: nil, null: false
    t.datetime "updated_at", precision: nil, null: false
    t.index ["namespace"], name: "index_minter_states_on_namespace", unique: true
  end

  create_table "orm_resources", id: :uuid, default: -> { "uuid_generate_v4()" }, force: :cascade do |t|
    t.jsonb "metadata", default: {}, null: false
    t.datetime "created_at", precision: nil, null: false
    t.datetime "updated_at", precision: nil, null: false
    t.string "internal_resource"
    t.integer "lock_version"
    t.index ["internal_resource"], name: "index_orm_resources_on_internal_resource"
    t.index ["metadata"], name: "index_orm_resources_on_metadata", using: :gin
    t.index ["metadata"], name: "index_orm_resources_on_metadata_jsonb_path_ops", opclass: :jsonb_path_ops, using: :gin
    t.index ["updated_at"], name: "index_orm_resources_on_updated_at"
  end

  create_table "users", force: :cascade do |t|
    t.string "email", default: "", null: false
    t.string "encrypted_password", default: "", null: false
    t.string "reset_password_token"
    t.datetime "reset_password_sent_at"
    t.datetime "remember_created_at"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.string "name"
    t.string "nuid"
    t.string "jti", null: false
    t.text "groups"
    t.integer "role", default: 2
    t.string "affiliation"
    t.boolean "preferred", default: false, null: false
    t.index ["email"], name: "index_users_on_email", unique: true
    t.index ["jti"], name: "index_users_on_jti", unique: true
    t.index ["nuid"], name: "index_users_on_nuid"
    t.index ["nuid"], name: "index_users_on_preferred_nuid", unique: true, where: "preferred"
    t.index ["reset_password_token"], name: "index_users_on_reset_password_token", unique: true
  end

  add_foreign_key "compilation_collection_inclusions", "compilations", on_delete: :cascade
  add_foreign_key "compilation_exclusions", "compilations", on_delete: :cascade
  add_foreign_key "compilation_work_inclusions", "compilations", on_delete: :cascade
  add_foreign_key "idempotency_keys", "users"
end
