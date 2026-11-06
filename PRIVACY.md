# Privacy policy

The published copy is at https://datpascal.github.io/loopr-legal/privacy.html. Keep both in step.

Last updated: 26 October 2026

> Short version. Loopr has no account, server, analytics service, or ads. Your data stays on your iPhone unless you choose to export it, publish a dashboard or protocol file, use Apple Health, add planned workouts to Calendar, look up a barcode with Open Food Facts, or share it with an AI provider. I, the developer, never receive your health data from the app.

## Who is responsible
Pascal Lindenau, Forddamm 7, 12107 Berlin, Germany. Email: [pascallindenau@googlemail.com](mailto:pascallindenau@googlemail.com). I am the controller under the EU General Data Protection Regulation (GDPR) for the little personal data that reaches me, which is described below.

## What Loopr stores on your iPhone
Depending on what you use, Loopr stores:

- readings from your band, such as heart rate, heart rate variability, motion and battery level;
- scores Loopr calculates from those readings, such as sleep, recovery and strain;
- your profile (for example age, height and weight), goals, journal entries, cycle entries and workouts;
- workout routes, if you record a workout with location turned on;
- meals, nutrients, drinks, food photos, favourites, targets and cached barcode products;
- data from Apple Health that you allow Loopr to read;
- blood test results you type in or scan, with the unit, reference range and flag the lab printed, and lab clock results such as DunedinPACE and GrimAge that you type in;
- your supplements and medication, with doses, an optional prescriber and notes, and a mark for each day you took or skipped one;
- your protocols with their versions and rules, how you kept each rule, and your experiments with their designs and results;
- capacity tests you record, such as grip strength, dead hang, sit to stand and one-leg balance, plus heart rate recovery from your workouts;
- weight, body fat and lean mass, typed in or read from Apple Health, each with its source;
- the blood age and Cardio Age Loopr works out, and the notes it writes on Today;
- your app settings;
- separate API keys for OpenAI and Claude, if you connect them;
- a list of the requests Loopr sent to your AI provider in the last 30 days, and the suggestions Ask made that still wait for your answer.

This data is stored in Loopr's own storage on the iPhone and in a shared app container that its widgets, Live Activities and Apple Watch app read from. Loopr does not send this data to a Loopr server. Optional sharing with an AI provider is described below.

The bedtime countdown on your lock screen and in the Dynamic Island is off until you turn it on. It shows your bedtime, the evening rules you wrote with their times, and which of them you have kept. It never shows a health reading.

If you back up your iPhone to iCloud or to a computer, the backup can include Loopr's data. Apple's terms cover those backups.

## Bluetooth and your band
Loopr talks to your band directly over Bluetooth. It does not connect to WHOOP's servers and never asks for WHOOP account details.

## Apple Health
Loopr reads and writes only the Apple Health data types you approve in the iOS permission sheet. You can change this at any time in the Health app or in iOS Settings. Deleting Loopr's own data does not delete what it saved to Apple Health. Loopr has a separate control for that.

Loopr reads sleep, heart rate, resting heart rate, heart rate variability (SDNN), respiratory rate, VO₂ max, steps, active energy, time in daylight, blood pressure, weight, body fat, lean body mass and blood glucose. It shows each value with the name of the app or device that recorded it, such as Apple Watch or Withings, and marks a value you typed in by hand. Each read has its own switch in Settings. When Apple Health returns nothing for a type, Loopr shows the value as missing and never fills in a zero.

Loopr saves only heart rate, resting heart rate, heart rate variability (SDNN), respiratory rate, sleep stages, estimated steps, estimated active energy and completed workouts. It writes none of the other types listed above. It never writes Cardio Age, blood age or any other Loopr score.

You can also type in weight, body fat and lean mass. A typed entry stays in Loopr, is marked as typed, and is not saved to Apple Health. What Loopr reads from Apple Health stays on your iPhone like everything else it stores.

## Blood tests and Lab mode
You can type in a blood test or photograph the report. Lab mode sits in the same camera as food capture. It reads the page with Apple's Vision text recognition on your iPhone, in English and German, and sends the photo nowhere. Loopr does not save the photo. It keeps the values you confirm, each with the unit, range and flag the lab printed. A photo from your library gives Loopr its date, and that date is used only when the report prints none. Loopr never calls a value abnormal and never sets a range of its own.

Loopr works out blood age on your iPhone with the PhenoAge formula, from nine markers and your age. Lab clock results such as DunedinPACE and GrimAge are numbers your lab reported. You type them in with the lab's name, and Loopr never calculates one.

Blood tests stay in Loopr's database on your iPhone. Loopr has no lock of its own, so anyone who can unlock your iPhone can open them. They leave it in four ways. You export or back up your data. You publish a dashboard that includes the Blood tests group. You share a file yourself. Or you turn on the Blood tests switch in Your data and send Ask a question, and then the values, units, ranges and flags go to your AI provider with that question. The switch is off until you turn it on.

## Supplements and medication
Supplements and medication are two separate lists, each with a morning and an evening part. For each item Loopr stores the name, the dose, a prescriber if you add one, your notes, and a mark for taken or skipped on each day. A day with no mark means not recorded. All of it stays on your iPhone. It leaves through an export, a backup, or the Supplements and medication switch for Ask, which is off until you turn it on. Even with the switch on, a lookup never sends the prescriber or your notes.

## Protocols, experiments and capacity tests
A protocol is a list of rules. Each rule has a target, an optional time, and a source that checks it, such as your band, Food, Fitness, Apple Health or a tick from you. Loopr keeps every saved version, how you kept each rule, and the experiments you run, with their design, outcome and result. Capacity tests keep what you record. Grip strength is typed in from a dynamometer. The iPhone times dead hang and one-leg balance. You score sit to stand yourself. Heart rate recovery comes from workouts you completed. The weekly dose adds up your zone 2, hard, strength and mobility time. Loopr works all of this out on the iPhone, and it leaves only through an export, a backup or an Ask switch.

You can share a protocol as a file through the share sheet or Files, and open a file someone else made. A file holds rules, targets, experiment designs, a name and an author you typed. It holds no health data, no check history, no results and nothing that identifies you. Opening a file reads it on your iPhone. A link inside a file is only text, and Loopr never loads it. From GitHub opens the community repository in Safari. Safari and GitHub handle that visit, and Loopr makes no request of its own.

## Coach notes on your iPhone
The morning note, the evening note, pattern lines and the weekly review on Today come from rules that run on your iPhone. They cost nothing, work offline and send nothing. When Apple's on-device language model is available, Loopr can ask it to reword a note. That model runs on your iPhone, and neither I nor an AI provider receives the text. If the reworded note holds a number that was not in the original, Loopr drops it and shows the rule's own text. Ask with your own key is a separate feature, covered under AI coaching.

## Publish a dashboard
Publish a dashboard builds one static page, as HTML and JSON, from the metrics and the period you pick. The groups are Sleep, Heart, Fitness, Food, Blood tests and Protocol. You see a preview first. The preview runs no script and cannot reach the internet. The file leaves Loopr only when you save or share it through the share sheet. Loopr uploads nothing and runs no server. Whatever you pick is in the file, so after you send it, the app or person you sent it to holds it. The page carries the line that Loopr is not a medical device.

## Reminders you set
These are notifications that iOS holds on your iPhone. They include reminders you confirm in Ask, the daily reminder of a Patterns test, the reminder for each part of your supplement and medication lists, the reminder at the time of an evening rule, and the Sunday evening reminder for the weekly review, which is off until you turn it on. A supplement or medication reminder names the part of the day, such as Morning stack, and never an item or a dose, because the lock screen shows it as written. An evening rule reminder shows the rule's title and the reason you wrote for it that morning, as you wrote it. The weekly review reminder only says the review is ready. Settings > Notifications lists every reminder with a Cancel button.

## Location
Loopr asks for location only to draw the route of a run, ride, walk or hike you record. Recording carries on with the screen locked, with the blue indicator showing, and stops when the workout ends. The route stays on the iPhone.

## Calendar
Loopr asks for Calendar access only when you turn on Add to Calendar for a training program. It asks for write-only access, so Loopr can add events and cannot read any of yours. Each event holds a workout name, its date and time, and a short note with the program name and week. Loopr saves the events to your default calendar for new events and keeps their identifiers on the iPhone, so a later change updates an event instead of adding a second one.

Turning the switch off removes the events Loopr added. If iOS will not hand an event back to Loopr, the event stays and you can delete it in Calendar. Loopr sends nothing to a server and adds no new network destination. If your default calendar belongs to iCloud or another account, that account syncs the events under its own terms. A program an agent drafts for you writes nothing to Calendar until you accept it and turn the switch on.

## AI coaching
The optional coach connects directly to OpenAI or Anthropic over HTTPS using your personal API key. Each provider has a separate device-only Keychain entry. Keys become accessible after the first unlock following a restart so explicitly enabled morning briefings can run in the background. Loopr does not bundle a shared key or route requests through a Loopr server.

Before the first message, Loopr shows the exact health summary and asks for consent for that conversation and provider. Follow-up messages reuse that summary and conversation. Your data has eight switches, one for each kind of record: band metrics and sleep, food log, training, journal answers, journal notes, cycle, supplements and medication, and blood tests. Journal notes, cycle, supplements and medication, and blood tests start off. If you update from an earlier build, those four stay off until you turn them on. Ask reads a kind of record only when its switch is on and the chat shares it. Loopr checks the switch again at every read, so turning one off stops the next read, even in a chat that is already open. Changing what a chat shares, or turning a switch off, starts a new chat so earlier replies cannot carry excluded data into the next request. Your messages and any custom coaching instructions also go to the provider.

The summary can include 14 calendar days of measurements, averages over available records from 30 days, up to six recent workouts, and current goals. It excludes raw sensor records, route coordinates, and your profile name. Optional journal and cycle sharing includes recent entries shown in the preview.

Ask can look things up while it answers. With each question, Loopr tells the provider which lookups exist: band metrics and sleep, food log, training, journal answers, journal notes, cycle records, and the patterns Loopr found. Seven more lookups follow the same switches. Your Protocol, how you kept it and your experiments sit under journal answers. Capacity tests and the weekly dose sit under training. Supplements and medication, and blood tests, each have their own switch in Your data, and no separate choice per chat. A Cardio Age and blood age lookup reads band metrics and blood tests, and Loopr Age is always reported as not available. The provider asks for one, Loopr runs it on your iPhone, and the result goes back to the provider together with your question. A lookup covers at most 120 days and returns at most 20 KB. Food photos are never part of a lookup. The supplements lookup sends what you took, skipped or have not recorded, and never the prescriber or your notes. The blood tests lookup sends values, units, ranges and flags exactly as the lab printed them, and Loopr adds no judgement of its own. An experiment result and the weekly zone minutes are worked out from band readings, so Loopr leaves them out while band metrics and sleep is off. If a lookup asks for something that is off, Loopr refuses it and tells the provider only that it is off. Text inside your notes and logs is passed along as data, never as instructions.

Ask does not change your data by itself. When it suggests a meal, a journal question, a change to a workout template, a training program, a reminder or a pattern test, you see a card with the details. Nothing is saved until you tap the confirm button. Not now saves nothing. A program stays a draft until you accept it in Fitness. A confirmed reminder is a notification scheduled on your iPhone. A reminder from Ask or from a pattern test lives only on the iPhone, and you manage it in Settings > Notifications, where each one is listed with its time and a Cancel button. A reminder arrives at the time you chose, even during quiet hours, and its title and body show on the lock screen as you confirmed them. Ask refuses to put a health reading in one. iOS asks for notification permission when you confirm the first reminder or start a test with one, and Loopr tells you on the card if you refuse. The list in Settings keeps a short local history of what was scheduled and what was not. That history is not part of the request log.

Loopr keeps a request log. It lists what Loopr sent to the provider in the last 30 days: when, which provider and model, why, and the exact request, including the health data and lookup results inside it. The log stays on your iPhone. You can read it in Your data under Request log, clear it at any time, and it is part of your exports. Delete all data removes it, and entries older than 30 days delete themselves. It never contains your API key. Clearing it cannot recall requests a provider already received.

Checking a key or refreshing models contacts the provider without sending health data. Automatic morning briefings are off by default and need separate consent to send a fresh summary each day. A briefing uses the same switches: it shares only what is on in Your data when it runs, even if you approved more earlier. Briefings stop when disabled or when the provider configuration changes. iOS controls background timing.

OpenAI requests set `store: false`, which does not guarantee zero provider retention. Both providers handle submitted data under their own terms and privacy policies. API usage is billed by the provider. ChatGPT and Claude app subscriptions do not include API usage.

Voice input uses on-device speech recognition where supported. Recognized text goes into a draft for you to review. Loopr does not send microphone audio to the AI provider.

## Food capture and estimates
Food photos, notes, meal times and reviewed nutrients stay in Loopr's local storage until you choose a sharing action. Nutrition-label recognition runs on the iPhone. Text and on-device voice entry, label scanning and manual edits work without an AI key. A food draft does not enter your food log until you tap Save. Saving a favourite is a separate confirmation.

For a photo estimate, Loopr asks for permission for the selected OpenAI or Claude configuration before sending the selected photo and your food note directly to that provider. It creates a smaller JPEG without the original location, capture-time or camera metadata. The photograph itself can still contain personal information. A correction sends the reviewed food names, portions, units, nutrient values and your correction text. It does not resend the photo when the draft already has food items.

Photo permission is separate from coach conversation consent. You can revoke it in meal review or the provider settings in Your data. Replacing a provider's key or model requires permission again. Revocation cancels pending work and prevents Loopr from accepting a late response. It cannot recall a request that already reached the provider. The providers may retain requests under their own policies; OpenAI's `store: false` does not establish zero retention. Loopr cannot verify a user's provider retention arrangement.

Scanning or entering a barcode sends that barcode to Open Food Facts over HTTPS. It also receives normal connection information, including your public IP address, and Loopr's app-identification header. The lookup sends no photo, food log, API key or health summary. In return Loopr asks for the product's name, brand, nutrition, NOVA group and ingredient list. Asking for more fields sends nothing more about you. Loopr reads the NOVA group and ingredients on your iPhone, for the ultra-processed share and the plants count. Product results are cached on your iPhone and can be used offline. Open Food Facts controls its server logs and retention. See its [privacy policy](https://world.openfoodfacts.org/privacy).

Food associations are calculated on the iPhone with the same statistical engine as Journal insights. They do not send a request to an AI provider. Missing nutrient values stay unknown. These comparisons describe associations and do not establish causes. Loopr does not write food or nutrition data to Apple Health.

## Patterns and comparisons
Patterns compares your own nights with each other. It looks for things like deep sleep after a late dinner or HRV after alcohol, using your journal answers, food log, training, steps and sleep. The statistics run on your iPhone with the same engine as Journal insights, and they send nothing to an AI provider. Loopr saves what it finds, your 14-day tests, your answers to them and a weekly review in its own storage. The weekly review is written on the iPhone. If you switch on morning briefings, a provider can word a briefing, and then only the facts your Your data switches allow leave the iPhone.

When you delete a workout, a habit answer, a day or a meal, Patterns hides every found pattern that used it as part of the same save. It counts again a few seconds after your last deletion, on the iPhone, if Look for new patterns is on. Patterns you dismissed stay dismissed. Deleting a journal entry does not change Patterns, because Patterns reads habit answers, not journal text.

Two cards use the same kind of on-device comparison. The pattern card on Today shows the strongest pattern Loopr found. The What was different card on Sleep compares a night with your last 28 days: dinner time, the alcohol answer, a workout the day before, bedtime and steps. Loopr works both out when you open the screen and does not save them. Tapping the Sleep card opens Ask with the question already typed. Ask sends nothing until you tap Send, and it reads only what your Your data switches allow.

These comparisons describe differences between your nights. They do not show what caused them.

## TestFlight
While Loopr is in beta, you install it through Apple's TestFlight app. Apple runs TestFlight and shares some data with me so I can fix problems:

- which build you installed, when you installed it and how often you opened it;
- crash reports, which include device model and iOS version;
- feedback and screenshots you choose to send from TestFlight;
- your name and email address, but only if I invited you by email. If you joined through the public link, Apple does not share your email address with me.

I use this data only to find and fix bugs, based on my legitimate interest in shipping a working app (Article 6(1)(f) GDPR). Feedback you send is voluntary. Apple keeps TestFlight data under its own privacy policy, and I delete what I receive when the beta ends or when you ask me to. Apple's own collection is covered by the [Apple Privacy Policy](https://www.apple.com/legal/privacy/) and the privacy notice in the TestFlight app.

## Email
If you email me, I use your address and message to answer you (Article 6(1)(b) and (f) GDPR). I delete the conversation when it is no longer needed, unless the law requires me to keep it.

## Where data leaves your iPhone
Loopr has no server of its own. Your data leaves the iPhone only when you start it, in these cases:

- you export or back up your data, or share a protocol file or a published dashboard;
- you turn on an Ask switch and send a question, so that kind of record can go to OpenAI or Anthropic;
- you give permission for an AI food estimate, and Loopr sends the photo or your correction;
- you scan or type a barcode, which goes to Open Food Facts;
- you let Apple Health save the types Loopr writes;
- you add planned workouts to Calendar.

Loopr contacts three internet addresses in total. world.openfoodfacts.org takes barcodes. api.openai.com and api.anthropic.com take Ask and food estimates, and only after you add your own key. Links to GitHub, research papers and provider pages open in Safari. This version adds no new address.

## Export and deletion
Your data offers exports of both SQLite databases and a ZIP with JSON, CSV and saved files. Full exports include confirmed food records, photos and favourites, the request log, and patterns with their tests and reviews. They also hold every table in Loopr's databases, so blood tests, supplements and medication, protocols, experiments, capacity tests, and weight and body composition entries are in them. SQLite copies also contain cached barcode products. A day export includes that day's food records and photos, but excludes your global favourites. Exports exclude API keys and Files folder permissions. Reminders you set are pending notifications that iOS holds, so they are not in an export. Settings > Notifications lists them and cancels them.

You can choose a folder in Files for weekly backups. A backup is a ZIP of every table, blood tests included, and Loopr does not encrypt it. Loopr saves a backup when you open the app and the last successful backup is at least a week old. You can also save one manually or turn backups off. The folder can belong to iCloud Drive or another Files provider you use. That provider's terms cover the copy. Deleting Loopr's data stops future backups and removes the saved folder permission. Copies you already exported or saved in Files remain where you put them.

In Loopr you can export your whole database as a file, delete a single day, or delete everything. Removing an AI provider cancels active requests and deletes its saved key and configuration. Saved chats remain until you delete them. Deleting all Loopr data stops coach work and removes food records, photos, favourites, barcode cache, chats, drafts, Ask suggestions, the request log, patterns, pattern tests, weekly reviews, every reminder you set, blood tests, supplements and medication, protocols, experiments, capacity tests, weight and body composition entries, consent records, briefing preferences, and provider keys. These actions cannot delete data a provider has already received. Deleting the app removes its storage from the iPhone, subject to how iOS handles backups and Keychain items.

## Your rights
Under the GDPR you can ask me for access to, correction of, or deletion of personal data I hold about you. You can also ask me to restrict or stop processing it, ask for a copy in a portable format, and object to processing based on legitimate interest. Write to [pascallindenau@googlemail.com](mailto:pascallindenau@googlemail.com).

You can also complain to a data protection authority. The one responsible for me is the Berliner Beauftragte für Datenschutz und Informationsfreiheit, Alt-Moabit 59-61, 10555 Berlin.

## Children
Loopr is not meant for anyone under 16.

## Changes
If Loopr starts handling data differently, I will update this page and the date at the top before that version ships.
