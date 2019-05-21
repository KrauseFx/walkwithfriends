require_relative "./database"
require 'telegram/bot'
require 'tempfile'
require 'json'

module StayInTouch
  class TelegramHandler
    class << self
      attr_accessor :last_command
    end

    def self.listen
      self.last_command ||= {}

      puts("Telegram server running...")
      self.perform_with_bot do |bot|
        @sending_out_thread ||= {}
        bot.listen do |message|
          begin
            if message.kind_of?(Telegram::Bot::Types::Message)
              self.did_receive_message(message: message, bot: bot)
            elsif message.kind_of?(Telegram::Bot::Types::CallbackQuery)
              self.did_receive_callback_query(message: message, bot: bot)
            end
          rescue StandardError => e
            # otherwise every crash causes the whole server to go down
            puts("#{e.message}\n" + e.backtrace.join("\n"))
          end
        end
      end
    end

    def self.did_receive_callback_query(message:, bot:)
      # Here you can handle your callbacks from inline buttons
      # currently used for the `/track` command and the number of minutes for a call
      from_username = message.from.username.downcase

      action = message.data.split("-")[0]

      if action == "track"
        user_to_confirm = message.data.split("-")[1..-1].join("-").downcase

        filtered_set = Database.database[:contacts].where(
          owner: from_username,
          telegramUser: user_to_confirm
        )

        if filtered_set.count > 0
          filtered_set.update(
            lastCall: Time.now,
            numberOfCalls: filtered_set.first[:numberOfCalls] + 1
          )

          bot.api.send_message(chat_id: message.from.id, text: "Alright, updated @#{user_to_confirm} last phone call")
        else
          bot.api.send_message(chat_id: message.from.id, text: "Couldn't find @#{user_to_confirm}, please make sure they're in your contact list")
        end
      elsif action == "callduration"
        # First, check if we have an existing thread going, that is sending out invites
        if @sending_out_thread[from_username]
          @sending_out_thread[from_username].exit
        end
        revoke_all_invites(bot: bot, owner: from_username)

        minutes = message.data.split("-").last.to_i
        to_send_out = []
        skipped_contacts = []

        sorted_contacts(from_username: from_username) do |current_contact|
          if current_contact[:lastCall]
            days_since_last_call = ((Time.now - current_contact[:lastCall]) / 60.0 / 60.0 / 24.0).round
            if days_since_last_call < 2
              # we just talked with them
              skipped_contacts << current_contact[:telegramUser]
              next
            end
          end

          telegram_id = Database.database[:openChats].where(telegramUser: current_contact[:telegramUser])
          if telegram_id.count == 0
            send_invite_text(bot: bot, chat_id: message.from.id, from: from_username, to: current_contact[:telegramUser])
          else
            to_send_out << {
              telegram_user: current_contact[:telegramUser],
              to_invite_chat_id: telegram_id.first[:chatId]
            }
          end
        end

        if skipped_contacts.count > 0
          bot.api.send_message(chat_id: message.from.id, text: "Skipped sending out messages to " + skipped_contacts.join(", ") + " as talked with them within the last 24h")
        end

        if to_send_out.count == 0
          bot.api.send_message(chat_id: message.from.id, text: "Looks like you don't have any contacts yet that confirmed the connection with the bot, please make sure to run /newcontact and let your friends connect with the bot")
        end

        @sending_out_thread[from_username] = Thread.new do
          to_send_out.each do |row|
            send_call_invite(
              bot: bot,
              author_chat_id: message.from.id,
              to_invite_chat_id: row[:to_invite_chat_id],
              telegram_user: row[:telegram_user],
              first_name: message.from.first_name,
              from_username: from_username,
              minutes: minutes
            )
            puts "sending to #{row[:telegram_user]}"
            sleep(10)
          end
          bot.api.send_message(
            chat_id: message.from.id,
            text: "Successfully pinged everyone from your contact list... now it's time to wait for someone to confirm"
          )
          sleep(5 * 60)
          bot.api.send_message(
            chat_id: message.from.id,
            text: "Looks like none of your friends is available... You can decide to wait a little longer, or just tap on /stop"
          )
        end
      else
        puts("Unknown action '#{action}'")
      end
    end

    # rubocop:disable Metrics/PerceivedComplexity
    def self.did_receive_message(message:, bot:)
      puts("Received #{message.text}")

      if message.from.username.nil?
        bot.api.send_message(chat_id: message.chat.id, text: "It looks like you didn't set a Telegram username yet, please go your Telegram profile and choose a username, and text me again once you did 🤗")
        return
      end
      from_username = message.from.username.downcase

      # ANY message we receive, we're gonna remember the mapping of username to Chat ID
      # to be able to text the given person. This is a privacy/spam protection feature, so that
      # bots can't start a new conversation
      if Database.database[:openChats].where(telegramUser: from_username).count == 0
        Database.database[:openChats] << {
          telegramUser: from_username
        }
      end
      Database.database[:openChats].where(telegramUser: from_username).update(chatId: message.chat.id)

      return if (message.text || "").length == 0

      case message.text.downcase
      when "/start"
        Thread.new do
          send_greeting(bot: bot, chat_id: message.chat.id)
        end
      when "/help"
        show_help_screen(bot: bot, chat_id: message.chat.id)
      when "/free"
        durations = [10, 20, 30, 45].collect do |duration|
          Telegram::Bot::Types::InlineKeyboardButton.new(
            text: "#{duration} minutes",
            callback_data: "callduration-#{duration}"
          )
        end
        markup = Telegram::Bot::Types::InlineKeyboardMarkup.new(inline_keyboard: durations)
        bot.api.send_message(chat_id: message.chat.id, text: "Roughly, how many minutes are you available?", reply_markup: markup)
      when "/stop"
        if @sending_out_thread[from_username]
          @sending_out_thread[from_username].exit
        end
        revoke_all_invites(bot: bot, owner: from_username)
        bot.api.send_message(chat_id: message.chat.id, text: "Alright, revoked all sent out invites")
      when %r{/revoke\_(.*)}
        username = message.text.match(%r{/revoke\_(.*)})[1].gsub("@", "").downcase
        matching_chats = Database.database[:openChats].where(telegramUser: username)
        if matching_chats.count == 0
          bot.api.send_message(chat_id: message.chat.id, text: "Could not find @#{username}")
        else
          chat_id = matching_chats.first[:chatId]

          applied_messages = Database.database[:openInvites].where(owner: from_username, chatId: chat_id)
          if applied_messages.count > 0
            bot.api.delete_message(chat_id: applied_messages.first[:chatId], message_id: applied_messages.first[:messageId])
            applied_messages.delete
            bot.api.send_message(chat_id: message.chat.id, text: "Successfully revoked invite for @#{username}")
          else
            bot.api.send_message(chat_id: message.chat.id, text: "@#{username} is already revoked")
          end
        end
      when "/track"
        contact_buttons = []
        sorted_contacts(from_username: from_username) do |contact|
          contact_buttons << Telegram::Bot::Types::InlineKeyboardButton.new(
            text: contact[:telegramUser],
            callback_data: "track-#{contact[:telegramUser]}"
          )
        end
        markup = Telegram::Bot::Types::InlineKeyboardMarkup.new(inline_keyboard: contact_buttons)
        bot.api.send_message(chat_id: message.chat.id, text: "Who did you talk with?", reply_markup: markup)
      when %r{/confirm\_(.*)}
        user_to_confirm = message.text.match(%r{/confirm\_(.*)})[1].gsub("@", "").downcase

        if @sending_out_thread[user_to_confirm]
          @sending_out_thread[user_to_confirm].exit
        end

        all_matches = Database.database[:openChats].where(telegramUser: user_to_confirm)
        if all_matches.count > 0
          telegram_id_owner = all_matches.first[:chatId]
          bot.api.send_message(chat_id: telegram_id_owner, text: "@#{from_username} just confirmed the call, you two should connect 🤗")

          bot.api.send_message(chat_id: message.chat.id, text: "Call confirmed, please hit the call button to connect with @#{user_to_confirm}")

          # now revoke all other messages
          revoke_all_invites(bot: bot, owner: user_to_confirm)

          # Update `lastCall` and `numberOfCalls` for the original user
          filtered_set = Database.database[:contacts].where(
            owner: user_to_confirm,
            telegramUser: from_username
          )

          if filtered_set.count > 0
            filtered_set.update(
              lastCall: Time.now,
              numberOfCalls: filtered_set.first[:numberOfCalls] + 1
            )
          else
            bot.api.send_message(chat_id: telegram_id_owner, text: "Couldn't find @#{user_to_confirm}, please make sure they're in your contact list")
          end

          # If both users use the bot, we have to update the entry for both relationships
          filtered_set = Database.database[:contacts].where(
            owner: from_username,
            telegramUser: user_to_confirm
          )
          if filtered_set.count > 0
            filtered_set.update(
              lastCall: Time.now,
              numberOfCalls: filtered_set.first[:numberOfCalls] + 1
            )
          end
          # No error message needed on `else`
        else
          bot.api.send_message(chat_id: telegram_id_owner, text: "Couldn't find @#{user_to_confirm}, please make sure they're connected to the bot")
        end
      when "/contacts"
        # we do custom handling `NULL` values as forever ago
        to_print = []

        sorted_contacts(from_username: from_username) do |row|
          if row[:lastCall]
            days_since_last_call = ((Time.now - row[:lastCall]) / 60.0 / 60.0 / 24.0).round

            emoji = if days_since_last_call > 7
                      "➡"
                    else
                      "✅"
                    end

            formatted_days_ago = "#{days_since_last_call} day" + (days_since_last_call != 1 ? "s" : "") + " ago"
            formatted_days_ago = "Today" if days_since_last_call == 0
          else
            emoji = "➡"
            formatted_days_ago = "Never"
          end

          if Database.database[:openChats].where(telegramUser: row[:telegramUser]).count == 0
            formatted_days_ago = "Didn't accept invite"
            emoji = "🧶"
          end

          number_of_calls_string = "(#{row[:numberOfCalls]} call" + (row[:numberOfCalls] != 1 ? "s" : "") + ")"
          string_to_insert = "#{emoji} #{formatted_days_ago}: @#{row[:telegramUser]} #{number_of_calls_string}"

          if row[:lastCall]
            to_print.insert(-1, string_to_insert)
          else
            to_print.insert(0, string_to_insert)
          end
        end

        if to_print.count > 0
          bot.api.send_message(
            chat_id: message.chat.id,
            text: to_print.join("\n")
          )
        else
          bot.api.send_message(
            chat_id: message.chat.id,
            text: "No contacts stored yet, please run /newcontact [telegram user] to add one"
          )
        end
      when "/stats"
        number_of_hosts = Database.database[:contacts].select_group(:owner).count
        number_of_clients = Database.database[:contacts].count
        number_of_open_messages = Database.database[:openInvites].count
        number_of_connected_calls = Database.database[:contacts].sum(:numberOfCalls)

        bot.api.send_message(
          chat_id: message.chat.id,
          text: [
            "#{number_of_hosts} people use the bot to schedule calls",
            "#{number_of_clients} people are in the users' addressbook",
            "#{number_of_connected_calls} calls connected with this bot",
            "#{number_of_open_messages} active message invites are sent out right now"
          ].join("\n")
        )
      when %r{/newcontact (.*)}
        username = message.text.match(%r{/newcontact (.*)})[1].gsub("@", "").downcase
        new_contact(username: username, bot: bot, message_chat_id: message.chat.id, from_username: from_username)
      when %r{/removecontact (.*)}
        username = message.text.match(%r{/removecontact (.*)})[1].gsub("@", "").downcase

        contacts = Database.database[:contacts].where(owner: from_username, telegramUser: username)
        if contacts.count == 1
          contacts.delete
          bot.api.send_message(chat_id: message.chat.id, text: "Successfully removed @#{username} from your contact list")
        else
          bot.api.send_message(chat_id: message.chat.id, text: "Could not find contact named @#{username}, please run /contacts for a list of your contacts")
        end
      when "/newcontact"
        # This happens when the user hits the /newcontact auto-complete button
        # and Telegram doesn't allow entering the actual value, so we will ask for it instead
        bot.api.send_message(chat_id: message.chat.id, text: "Please send me the Telegram username of your friend, the username can be found in the user's profile. If they don't have one yet, they'll have to claim their Telegram username, as it's used to identify them for this bot")
        self.last_command[message.chat.id] = :newcontact
        Thread.new do
          sleep(500)
          # TODO: Terrible workaround to reset state
          # when the user never sent a username, we reset it again
          self.last_command[message.chat.id] = nil
        end
      when "/removecontact"
        # This happens when the user hits the /removecontact auto-complete button
        bot.api.send_message(chat_id: message.chat.id, text: "Please enter `/removecontact username` in one line to remove a user")
      else
        if self.last_command[message.chat.id] == :newcontact
          username = message.text.gsub("@", "").downcase
          if new_contact(username: username, bot: bot, message_chat_id: message.chat.id, from_username: from_username) == true
            self.last_command[message.chat.id] = nil
          end
        else
          bot.api.send_message(chat_id: message.chat.id, text: "Sorry, I couldn't understand what you're trying to do")
          show_help_screen(bot: bot, chat_id: message.chat.id)
        end
      end
    end
    # rubocop:enable Metrics/PerceivedComplexity

    # either provide a block or use the return value
    def self.sorted_contacts(from_username:)
      # we do custom handling `NULL` values as forever ago
      sorted_list = []

      Database.database[:contacts].where(owner: from_username).order(:lastCall).each do |row|
        if row[:lastCall]
          sorted_list.insert(-1, row)
        else
          sorted_list.insert(0, row)
        end
      end

      sorted_list.each do |row|
        yield(row)
      end

      return sorted_list
    end

    def self.new_contact(username:, bot:, message_chat_id:, from_username:)
      if username.include?(" ")
        bot.api.send_message(chat_id: message_chat_id, text: "Username must be the Telegram username, no spaces allowed")
        return false
      end

      contacts = Database.database[:contacts].where(owner: from_username, telegramUser: username)

      if contacts.count == 0
        Database.database[:contacts] << {
          lastCall: nil,
          owner: from_username,
          telegramUser: username
        }
        bot.api.send_message(chat_id: message_chat_id, text: "✅ New contact saved")
      else
        bot.api.send_message(chat_id: message_chat_id, text: "⚠️ Looks like you already have @#{username} in your contact list")
      end

      if Database.database[:openChats].where(telegramUser: username).count == 0
        send_invite_text(bot: bot, chat_id: message_chat_id, from: from_username, to: username)
      end

      return true
    end

    def self.revoke_all_invites(bot:, owner:)
      Database.database[:openInvites].where(owner: owner).each do |current_message|
        begin
          bot.api.delete_message(chat_id: current_message[:chatId], message_id: current_message[:messageId])
        rescue StandardError => e
          # We don't want things to get stuck if a message is stuck
          puts(e)
        end
      end
      Database.database[:openInvites].where(owner: owner).delete
    end

    def self.show_help_screen(bot:, chat_id:)
      bot.api.send_message(
        chat_id: chat_id,
        text: ["The following commands are available:\n",
               "/newcontact [name] Add a new contact (Telegram username)",
               "/removecontact [name] Remove a contact",
               "/contacts List all contacts you have",
               "/free Mark yourself as free for a call",
               "/stop Mark yourself as unavailable",
               "/track [name] Manually track a call, e.g. if you hang out IRL",
               "/stats Show the number of users of this bot",
               "/help Print this help screen"].join("\n")
      )
    end

    def self.send_invite_text(bot:, chat_id:, from:, to:)
      bot.api.send_message(chat_id: chat_id, text: "Looks like @#{to} didn't connect with the bot yet, please forward the following message to them:\n\n\n")
      bot.api.send_message(chat_id: chat_id, text: "Hey @#{to}, I'd like to add you to my call list for https://walkwithfriends.net/, please tap on https://t.me/WalkWithFriendsBot and hit `Start` to confirm")
    end

    def self.send_greeting(bot:, chat_id:)
      messages = [
        "Staying in touch with close friends requires more effort when everybody lives somewhere else on the planet. Scheduling calls to catch up certainly works, but it requires time-commitment, and time zones make scheduling unnecessarily complicated.",
        "After living in NYC for a year, I ended up doing the following: If I walk somewhere for about 30 minutes, I'd text 2 friends or family members, asking if they're available for a chat. Often one of them would end up calling me. This way, no prior " \
          "planning was necessary, things felt more spontaneous and I was able to use my NYC walking time, a city in which I walk 20,000 steps a day on average.",
        "The problems:",
        "- If I text a friend Hey X, are you free for a call?, chances are they're at work, asleep, with friends or don't look at their phone. They'd see my message 2 hours later and reply Yep, sure, calling you now. The problem here is that by that time I'm unavailable, as the message is from 2 hours ago.",
        "- If a friend doesn't know about this setup, they'd think I want to discuss something specific or urgent, however those kinds of calls are just to catch up and stay in touch.",
        "- Often, either none of my friends were available, or multiple responded, so it was always a tricky balance on how many friends I'd text, with the risk of both of them replying Yep, I'm free now",
        "- If one friend is never available, you kind of \"forget\" to text them, as you already assume subconsciously that they won't be available",
        "The solution: A Telegam bot that manages the communication for me and revokes messages as soon as I'm unavailable again."
      ]
      messages.each do |message|
        bot.api.send_message(chat_id: chat_id, text: message)
        sleep(message.length / 50.0 + 1.0)
      end

      bot.api.send_photo(
        chat_id: chat_id,
        photo: Faraday::UploadIO.new('./assets/how-does-it-work.png', 'image/png')
      )

      sleep(5)

      ["screenshot1_framed", "screenshot2_framed", "screenshot3_framed"].each do |file_name|
        bot.api.send_photo(
          chat_id: chat_id,
          photo: Faraday::UploadIO.new("./assets/#{file_name}.png", 'image/png')
        )
      end

      bot.api.send_message(chat_id: chat_id, text: "If you got invited to this bot, you're now successfully set up, nothing else you need to do. You'll automatically get a notification once the other person is available")
      sleep(2)
      bot.api.send_message(chat_id: chat_id, text: "If you want to use this bot, just tap on /help to get started")
    end

    def self.send_call_invite(bot:, author_chat_id:, to_invite_chat_id:, telegram_user:, first_name:, from_username:, minutes:)
      bot.api.send_message(chat_id: author_chat_id, text: "Pinging @#{telegram_user}... (/revoke_#{telegram_user} to skip)")

      message_id = bot.api.send_message(
        chat_id: to_invite_chat_id,
        text: "Hey #{telegram_user}\n\n@#{from_username} is available for a call for about #{minutes} minutes, please tap /confirm_#{from_username} if you're free to chat now :)"
      )["result"]["message_id"]

      Database.database[:openInvites] << {
        owner: from_username,
        messageId: message_id,
        chatId: to_invite_chat_id
      }
    end

    def self.perform_with_bot
      # https://github.com/atipugin/telegram-bot-ruby
      yield(self.client)
    rescue StandardError => e
      puts("error sending the telegram notification")
      puts(e)
      puts(e.backtrace)
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
