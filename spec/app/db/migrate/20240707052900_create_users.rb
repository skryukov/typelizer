class CreateUsers < ActiveRecord::Migration[7.1]
  def change
    create_table :users do |t|
      t.string :username, null: false
      t.boolean :active, null: false, default: false
      t.references :invitor, foreign_key: {to_table: "users"}

      t.timestamps
    end
  end
end
