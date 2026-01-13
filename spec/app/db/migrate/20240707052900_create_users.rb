class CreateUsers < ActiveRecord::Migration[7.1]
  def change
    create_table :users do |t|
      t.string :name, null: false
      t.string :username, null: false
      t.boolean :active, null: false, default: false
      t.references :invitor, foreign_key: {to_table: "users"}
      t.integer :role, null: false, default: 0

      t.timestamps
    end
  end
end
