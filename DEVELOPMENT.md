# Development

You'll have to setup a few things

- Create a Telegram bot using @BotFather and get the API key
- Provide those values using `TELEGRAM_TOKEN`
- Host it on any server, like Heroku
- Make sure the Heroku worker is enabled

## Telegram commands

```
free - available for a call
stop - mark yourself as unavailable for a call
newcontact - [name] Add a new contact
removecontact - [name] Remove an existing contact
contacts - list all your contacts
track - manually track a call if you hung out IRL
stats - print basic stats about this bot
help - print help screen
```

## Dependencies

```
bundle install
```

```
bundle exec ruby worker.rb
```

## Environment variables

```
TELEGRAM_TOKEN
DATABASE_URL
```
