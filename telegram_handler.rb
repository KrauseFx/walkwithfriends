require_relative "./database"
require 'telegram/bot'
require 'tempfile'
require 'json'

module StayInTouch
  class TelegramHandler
    def self.listen
      puts "Telegram server running..."
      self.perform_with_bot do |bot|
        bot.listen do |message|
          self.did_receive_message(message: message, bot: bot)
        end
      end
    end

    def self.did_receive_message(message:, bot:)
      puts "Received #{message.text}"
      from_username = message.from.username

      # ANY message we receive, we're gonna remember the mapping of username to Chat ID
      # to be able to text the given person. This is a privacy/spam protection feature, so that
      # bots can't start a new conversation
      if Database.database[:openChats].where(telegramUser: from_username).count == 0
        Database.database[:openChats] << {
          telegramUser: from_username
        }
      end
      Database.database[:openChats].where(telegramUser: from_username).update(chatId: message.chat.id)

      case message.text
        when "/start"
          bot.api.send_message(chat_id: message.chat.id, text: "Hey @#{from_username}, thanks for confirming, you'll receive call requests here as soon as the other party is available.\n\nIf you want, you can also use this bot to connect with your friends across the world, just run `/help` to get a list of all available commands.")
        when "/help"
          show_help_screen(bot: bot, chat_id: message.chat.id)
        when "/free"
          Database.database[:contacts].where(owner: from_username).reverse_order(:lastCall).each do |current_contact|
            telegram_id = Database.database[:openChats].where(telegramUser: current_contact[:telegramUser])
            if telegram_id.count == 0
              send_invite_text(bot: bot, chat_id: message.chat.id, from: from_username, to: current_contact[:telegramUser])
            else
              bot.api.send_message(chat_id: message.chat.id, text: "Pinging @#{current_contact[:telegramUser]}")

              to_chat_id = telegram_id.first[:chatId]
              message_id = bot.api.send_message(
                chat_id: to_chat_id,
                text: "Hey #{current_contact[:telegramUser]}\n\n@#{message.from.first_name} is available for a call, please tap /confirm_#{from_username} if you're free to chat now :)"
              )["result"]["message_id"]

              Database.database[:openInvites] << {
                owner: from_username,
                messageId: message_id,
                chatId: to_chat_id
              }
            end
          end
        when "/stop"
          revoke_all_invites(bot: bot, owner: from_username)
          bot.api.send_message(chat_id: message.chat.id, text: "Alright, revoked all sent out invites")
        when /\/confirm\_(.*)/
          user_to_confirm = message.text.match(/\/confirm\_(.*)/)[1]

          bot.api.send_message(chat_id: message.chat.id, text: "Call confirmed, please hit the call button to connect with @#{user_to_confirm}")

          telegram_id_owner = Database.database[:openChats].where(telegramUser: user_to_confirm).first[:chatId]
          bot.api.send_message(chat_id: telegram_id_owner, text: "@#{message.from.username} just confirmed the call, you two should connect 🤗")
          
          # now revoke all other messages
          revoke_all_invites(bot: bot, owner: user_to_confirm)

          Database.database[:contacts].where(owner: user_to_confirm, telegramUser: message.from.username).update(lastCall: Time.now)
        when "/contacts"
          to_print = Database.database[:contacts].where(owner: from_username).reverse_order(:lastCall).collect do |row|
            if row[:lastCall]
              formatted_date = row[:lastCall].strftime("%Y-%m-%d")
              days_since_last_call = ((Time.now - row[:lastCall]) / 60.0 / 60.0 / 24.0).round

              emoji = if days_since_last_call > 7
                "➡"
              else
                "✅"
              end

              formatted_days_ago = " #{days_since_last_call} day" + (formatted_days_ago != 1 ? "s" : "") + " ago"
            else
              formatted_date = "Not yet called"
              emoji = "➡"
              formatted_days_ago = ""
            end

            "#{emoji}#{formatted_days_ago}: #{row[:telegramUser]}: #{formatted_date}"
          end
          bot.api.send_message(
            chat_id: message.chat.id,
            text: to_print.join("\n")
          )
        when /\/newcontact (.*)/
          username = message.text.match(/\/newcontact (.*)/)[1].gsub("@", "")
          Database.database[:contacts] << {
            lastCall: nil,
            owner: from_username,
            telegramUser: username
          }
          bot.api.send_message(chat_id: message.chat.id, text: "✅ New contact saved")

          if Database.database[:openChats].where(telegramUser: username).count == 0
            send_invite_text(bot: bot, chat_id: message.chat.id, from: from_username, to: username)
          end
        when "/newcontact"
          bot.api.send_message(chat_id: message.chat.id, text: "Please enter `/newcontact [username]`")
        else
          bot.api.send_message(chat_id: message.chat.id, text: "Sorry, I couldn't understand what you're trying to do")
          show_help_screen(bot: bot, chat_id: message.chat.id)
      end
    end

    def self.revoke_all_invites(bot:, owner:)
      Database.database[:openInvites].where(owner: owner).each do |current_message|
        begin
          bot.api.delete_message(chat_id: current_message[:chatId], message_id: current_message[:messageId])
        rescue => ex
          # We don't want things to get stuck if a message is stuck
          puts ex
        end
      end
      Database.database[:openInvites].where(owner: owner).delete
    end

    def self.show_help_screen(bot:, chat_id:)
      bot.api.send_message(
        chat_id: chat_id,
        text: ["The following commands are available:\n\n",
              "/newcontact [name] Add a new contact (Telegram username)",
              "/contacts List all contacts you have",
              "/free Mark yourself as free for a call",
              "/stop Mark yourself as unavailable",
              "/help Print this help screen"].join("\n")
      )
    end

    def self.send_invite_text(bot:, chat_id:, from:, to:)
      bot.api.send_message(chat_id: chat_id, text: "Looks like @#{to} didn't connect with the bot yet, please forward the following message to them:\n\n\n")
      bot.api.send_message(chat_id: chat_id, text: "@#{from} wants to add you to his call list so you can stay connected, please confirm by tapping the following link: https://t.me/StayInTouchBot and hit `Start`")
    end

    def self.perform_with_bot
      # https://github.com/atipugin/telegram-bot-ruby
      yield self.client
    rescue => ex
      puts "error sending the telegram notification"
      puts ex
      puts ex.backtrace
    end

    def self.client
      return @client if @client
      raise "No Telegram token provided on `TELEGRAM_TOKEN`" if token.to_s.length == 0
      @client = ::Telegram::Bot::Client.new(token)
    end

    def self.token
      ENV["TELEGRAM_TOKEN"]
    end
  end
end
