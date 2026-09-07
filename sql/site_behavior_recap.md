# What 391 visits taught me about how people use my site

My first real SQL project, start to finish — I built cookie-free, first-party analytics into the site a while back, and this spring I finally queried ten weeks of it: 391 visits, ~9,700 events.

**What people actually do:**
- The kiss button gets tapped immediately (first move in 40% of engaged visits) and kept tapping long past getting anything new back — a 96% revisit rate within the same visit. One real reader (not me testing) in East Providence hit 29 clicks in a single sitting.
- Spotify's mini-game is the opposite instinct: a real, goal-chasing minority actually plays toward the win instead of just poking at it.
- Photo gallery and the kiss button feed each other — bouncing between the two is the single most common thing anyone does.
- The games shelf barely gets opened, but the few who do open it play real trivia/guessing games (openguessr, framed, colorguesser) rather than just clicking around — the same "give people a goal" pattern as Spotify, just smaller.
- Most-clicked outbound links: my Spotify profile (49 clicks) narrowly ahead of dropkickd (46), then Twitter/X (37), kritiquekapital.com (32), Letterboxd (24), Backloggd (13), Duolingo (11), Substack proper (7), and Stats.fm (7).
- The "laptop" device tag turned out to be a red herring: 77% of visits tagged laptop trace back to the same crawler-fingerprint cities as everything else. Desktop and mobile visitors engage at 70–80%; "laptop" visits engage at 15%. It's basically a bot tag wearing a device label.

**By the numbers**

391 visits · 227 sessions · 619 pageviews · 9,116 interactions

- 1,654 kisses, 194 sinks
- 3,929 photo clicks
- 175 goals scored (151 desktop / 24 mobile)
- Theme switches → photo clicks while that theme was active (retro is also the default starting theme, cycling in fixed order — art, space, rain, glitch, etc. — on mobile, so its lead isn't pure preference):
  - retro: 475 switches → 1,481 photo clicks
  - rain: 184 → 788
  - space: 220 → 734
  - art: 259 → 476
  - glitch: 117 → 202
  - classic: 40 → 99
  - modern: 58 → 89
  - lofi: 30 → 47
  - logistics: 32 → 13
  - nature: 31 → 0
- Of 52 distinct cities in the raw data, 15 show actual clicking behavior — the rest (all international traffic included) fire the exact same no-click, page-load-only fingerprint you'd expect from crawlers, not readers. The 15 real ones: Revere, East Providence, Amherst, Saugus, Boston, Bridgeport, Haverhill, Baltimore, Everett, Gorham, Avon, Cheshire, Northampton, Oakland City, and Salem.

**What I learned**

- *User behavior:* people gravitate to the feel of a response over the content of it — the kiss button's draw is the tap, not what's behind it. Give the same crowd an actual goal and a real (smaller) chunk will chase it properly. Features cluster into habits, not isolated visits.
- *Site design:* retro leads theme usage by a wide margin, though it's also the default/starting theme, so some of that lead is exposure, not pure preference — worth watching whether it holds up if the rotation order ever changes. Also: raw hit counts lie. A big chunk of "traffic" is crawlers touching everything uniformly, so real signal has to come from behavior, not volume.
- *Data/tracking:* the export encoded "missing" two different ways (blank string vs. a literal placeholder) depending on the column, which silently broke my traffic-source classification until I checked raw values instead of trusting a "zero nulls" summary. Background auto-fire events can make a feature look wildly popular in raw counts while barely being touched on purpose — always separate "fired" from "deliberately triggered." Building this in layers (staging → dimensions → facts → analysis) made bugs easy to isolate instead of hunting through one giant query.

Rather than narrate everything else — go [click around yourself](https://kritiquekapital.com) and see where you land.

*Data: first-party, cookie-free, March 24–May 31, 2026. No cross-visit tracking, so a returning visitor looks like a new one.*
