require "sequel"

module StayInTouch
  class Database
    def self.database
      @_db ||= Sequel.connect(ENV["DATABASE_URL"])

      unless @_db.table_exists?("contacts")
        @_db.create_table(:contacts) do
          primary_key :id
          DateTime :lastCall
          String :owner
          String :telegramUser
          Integer :numberOfCalls, default: 0
        end
      end

      unless @_db.table_exists?("openChats")
        @_db.create_table(:openChats) do
          primary_key :id
          String :telegramUser
          Integer :chatId
        end
      end

      unless @_db.table_exists?("openInvites")
        @_db.create_table(:openInvites) do
          primary_key :id
          String :owner
          Integer :messageId
          Integer :chatId
        end
      end

      return @_db
    end
  end
end
