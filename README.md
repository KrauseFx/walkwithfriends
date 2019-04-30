# StayInTouch

## How to use it

You'll have to setup a few things

- Create a Telegram bot using @BotFather and get the API key, and message ID with you
- Provide those values using `TELEGRAM_TOKEN`
- Host it on any server, like Heroku
- Make sure the Heroku worker is enabled

## Telegram commands

```
free - available for a call
stop - mark yourself as unavailable for a call
newcontact - [name] Add a new contact
contacts - list all your contacts
help - print help screen
```

## Development

### Dependencies

```
bundle install
```

```
bundle exec ruby worker.rb
```

### Environment variables

```
TELEGRAM_TOKEN
DATABASE_URL
```
