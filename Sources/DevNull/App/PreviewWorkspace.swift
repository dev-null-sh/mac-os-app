#if DEBUG
    import Foundation

    /// The preview's answers for everything besides Remotes: logs, commits and their threads, notifications, profiles,
    /// Starred, the scheduled queue, search, composer suggestions and settings. Every person is made up. About every 45
    /// seconds someone the preview follows commits, so polling and "↑ N new commits" can be tried.
    final class PreviewWorkspaceStore: @unchecked Sendable {
        static let shared = PreviewWorkspaceStore()

        private let lock = NSLock()
        private var commits: [String: [String: Any]] = [:]
        /// Top-level commits, newest first.
        private var timeline: [String] = []
        private var replies: [String: [String]] = [:]
        private var starredIds: [String] = []
        private var scheduled: [[String: Any]] = []
        private var notifications: [[String: Any]] = []
        private var unreadNotifications = 5
        private var following: Set<String> = ["maya", "jonasw", "anaribeiro", "priya", "leom", "tom"]
        private var muted: Set<String> = []
        private var blocked: Set<String> = []
        private var pinnedId: String?
        private var lastArrivalAt = Date()
        private var settings: [String: Any] = ["timezone": NSNull(), "show_local_time": false, "translation_language": NSNull(), "automatic_translation": true, "is_admin": true]
        private var devices: [[String: Any]] = []
        private var lane: Any = NSNull()
        private var pasteisMode = true
        private var sequence = 0

        static let cast: [String: (name: String, lane: Int, bio: String)] = [
            "you": ("Preview You", 0, "Building things on /dev/null."),
            "maya": ("Maya Okafor", 1, "Design systems, type, and too much coffee. Ex-terminal emulator person."),
            "jonasw": ("Jonas Weber", 2, "Postgres, queues and retries. Mostly retries."),
            "anaribeiro": ("Ana Ribeiro", 3, "Shipping the iOS app from Porto."),
            "priya": ("Priya Raman", 4, "Infra and late-night deploys."),
            "leom": ("Leo Martins", 5, "Rust on weekends, PHP on weekdays."),
            "samc": ("Sam Chen", 0, "Writes the docs nobody reads (you should)."),
            "tom": ("Tom", 2, "The /dev/null bot. Answers questions about the site."),
            "theo": ("Theo Park", 2, "Backend. Queues. Retries."),
            "rosa": ("Rosa Díaz", 3, "Shipping the iOS app."),
            "sam": ("Sam Okafor", 4, "Infra and late-night deploys."),
            "lena": ("Lena Novak", 5, "Writes the docs nobody reads (you should)."),
            "ivan": ("Ivan Petrov", 2, "Rust, mostly."),
            "zoe": ("Zoë Martin", 4, "Product."),
        ]

        private static let bodies: [(String, String)] = [
            ("maya", "Postgres 18's async I/O cut our cold-cache reads by a third. Same hardware, same queries, one config line: `io_method = worker`."),
            ("jonasw", "Retries are a product decision, not an infrastructure one. If the user would rather see an error than wait 30s, don't retry for 30s."),
            ("anaribeiro", "TestFlight build 214 is out with the new composer. Drafts now survive the app being killed, which was the #1 request."),
            ("priya", "Deploy freeze starts Friday at 18:00. If it isn't merged by then it ships Monday, no exceptions (looking at myself)."),
            ("leom", "Today I learned `cargo tree -d` shows every crate you pull twice at different versions. We had four copies of `syn`.\n\n```sh\ncargo tree -d | grep -c syn\n4\n```"),
            ("maya", "New type scale is live behind the flag: 15/22 body, tighter headings, Geist Mono for anything a machine prints. Screenshots below."),
            ("tom", "Reminder: commits are never edited. Delete within 30 seconds to undo, or commit again. That's the whole policy."),
            ("jonasw", "Wrote up how we moved the notifications fan-out to a queue without double-sending: https://example.com/blog/fan-out"),
            ("samc", "Docs PR for the signed API is up. Every endpoint now says which web page it mirrors, so nobody has to guess what \"same rules\" means."),
            ("anaribeiro", "Which one do you reach for first when a build breaks on CI only?"),
            ("priya", "Our p99 dropped from 840ms to 190ms after removing one N+1 nobody noticed because the dev database had six rows.\n\n```php\n$commits->load('user', 'images');\n```"),
            ("maya", "Hot take: dark mode should be a different design, not the same design with the lights off."),
            ("leom", "Spent the morning on a flaky test. It was the timezone. It's always the timezone."),
            ("jonasw", "`EXPLAIN (ANALYZE, BUFFERS)` or it didn't happen."),
            ("tom", "Scheduled commits now show in your queue with the exact time they go out, in your timezone."),
            ("samc", "If your README starts with a badge wall, I'm closing the tab. Start with one sentence about what the thing does."),
            ("anaribeiro", "The App Store review took 11 minutes this time. Eleven. I don't know what to do with myself."),
            ("priya", "Rotated every credential after the incident drill. Found two that nobody could explain. Both gone now."),
            ("maya", "Small thing I love: a skeleton that's exactly the size of the content it stands for. Nothing jumps when the data arrives."),
            ("leom", "The borrow checker is a pair programmer who never gets tired and never lets you win an argument."),
            ("jonasw", "Moved our cron to the scheduler's `withoutOverlapping()` and the 3am pages stopped. Should've done it a year ago."),
            ("samc", "Writing the changelog is the best code review you'll do all week."),
            ("anaribeiro", "Haptics on the star button: on or off? I keep flip-flopping."),
            ("priya", "A 30s health check that hits the database is a 30s DDoS on yourself. Check the process, not the dependency."),
        ]

        private init() {
            seed()
        }

        // MARK: Fixtures

        private func uid(_ handle: String) -> String {
            handle == "you" ? "u-me" : "u-\(handle)"
        }

        private func user(_ handle: String) -> [String: Any] {
            let person = Self.cast[handle] ?? (handle.capitalized, 0, "")

            return [
                "id": uid(handle), "handle": handle, "name": person.name, "bio": person.bio, "lane": person.lane,
                "avatar_url": handle == "you" ? NSNull() : "https://\(Preview.host)/avatar/\(handle).png" as Any,
                "html_url": "https://\(Preview.host)/@\(handle)", "is_followed": following.contains(handle), "follows_you": handle.count % 2 == 0,
                "company": NSNull(), "location": ["Lagos", "Berlin", "Porto", "Bangalore", "Lisbon", "Toronto"][abs(handle.hashValue) % 6], "website": "https://example.com/\(handle)",
                "github_url": "https://github.com/\(handle)", "created_at": date(60 * 24 * Double(200 + handle.count * 30)),
            ]
        }

        private func date(_ minutesAgo: Double) -> String {
            Date(timeIntervalSinceNow: -minutesAgo * 60).formatted(.iso8601)
        }

        private func uuid() -> String {
            sequence += 1
            return String(format: "%08x-0000-4000-8000-%012x", sequence * 7919, sequence * 104_729)
        }

        @discardableResult
        private func makeCommit(_ handle: String, _ body: String, minutesAgo: Double, parent: String? = nil, extra: [String: Any] = [:]) -> String {
            let id = uuid()
            var commit: [String: Any] = [
                "id": id, "short_hash": String(id.replacingOccurrences(of: "-", with: "").suffix(7)), "body": body,
                "parent_id": parent ?? NSNull() as Any, "html_url": "https://\(Preview.host)/@\(handle)/\(id)",
                "created_at": date(minutesAgo), "stars_count": parent == nil ? Int.random(in: 0 ... 60) : Int.random(in: 0 ... 6),
                "replies_count": 0, "author": user(handle), "mentions": [], "status": "approved", "is_pinned": false,
                "starred": false, "pasteis_count": Int.random(in: 0 ... 3), "deleted_at": NSNull(), "quoted_commit_id": NSNull(),
                "images": [],
            ]
            extra.forEach { commit[$0.key] = $0.value }
            commits[id] = commit

            if let parent {
                replies[parent, default: []].append(id)
                let count = replies[parent]?.count ?? 0
                commits[parent]?["replies_count"] = count
            }

            return id
        }

        private func seed() {
            var minutes: Double = 4

            for (index, (handle, body)) in Self.bodies.enumerated() {
                var extra: [String: Any] = [:]

                if index == 5 {
                    extra["images"] = [image(21, 1600, 1000, "The new type scale on the log"), image(22, 1000, 1000, "Headings at three sizes")]
                }

                if index == 7 {
                    extra["link_preview"] = ["url": "https://example.com/blog/fan-out", "title": "Fanning out notifications without double-sending", "description": "A queue, an idempotency key, and one very boring table.", "image_url": "https://\(Preview.host)/img/9/1200x630.png", "site_name": "example.com"]
                }

                if index == 9 {
                    extra["poll"] = ["id": "poll-1", "closes_at": date(-60 * 24 * 2), "is_closed": false, "has_voted": false, "total_votes": NSNull(), "options": [
                        ["id": "opt-1", "label": "Re-run with SSH", "votes_count": NSNull(), "voted": false, "percentage": NSNull()],
                        ["id": "opt-2", "label": "Read the logs twice", "votes_count": NSNull(), "voted": false, "percentage": NSNull()],
                        ["id": "opt-3", "label": "Blame the cache", "votes_count": NSNull(), "voted": false, "percentage": NSNull()],
                    ]]
                }

                let id = makeCommit(handle, body, minutesAgo: minutes, extra: extra)
                timeline.append(id)
                minutes += Double(Int.random(in: 25 ... 260))

                if index % 3 == 0 {
                    for (offset, replier) in ["jonasw", "priya", "samc", "leom", "maya"].shuffled().prefix(Int.random(in: 1 ... 4)).enumerated() where replier != handle {
                        let reply = makeCommit(replier, ["Same here.", "This is the way.", "Do you have numbers for the warm cache too?", "Bookmarking this. Well, starring it.", "We hit the exact same thing last month."][offset % 5], minutesAgo: max(1, minutes - Double(offset * 20) - 300), parent: id)

                        // The first reply gets an answer, and that answer one more, so threads go a few levels deep.
                        if offset == 0 {
                            let answer = makeCommit(handle, "Warm cache is within noise, the win is all cold reads.", minutesAgo: max(1, minutes - 280), parent: reply)
                            makeCommit("tom", "Logged it: commits are never edited, but this thread is a good read.", minutesAgo: max(1, minutes - 270), parent: answer)
                        }
                    }
                }
            }

            // A reply that surfaces in Latest, and a quote of the type scale commit.
            if let first = timeline.first {
                let quote = makeCommit("anaribeiro", "This is what the iOS app is getting next. @maya you're a menace (complimentary).", minutesAgo: 2, extra: ["quoted_commit_id": timeline[5], "quoted_commit": commits[timeline[5]] ?? [:], "mentions": [["handle": "maya", "offset": 42, "length": 5]]])
                timeline.insert(quote, at: 0)
                _ = first
            }

            // The user's own commits, one pending review.
            let own = makeCommit("you", "Finally moved the Mac app to a workspace layout: logs, remotes and your pages in one sidebar.", minutesAgo: 600)
            timeline.insert(own, at: min(6, timeline.count))
            let pending = makeCommit("you", "Trying the new composer from the Mac.", minutesAgo: 1, extra: ["status": "pending"])
            timeline.insert(pending, at: 0)
            pinnedId = own
            commits[own]?["is_pinned"] = true

            starredIds = [timeline[2], timeline[4], timeline[9]]
            for id in starredIds { commits[id]?["starred"] = true }

            scheduled = [
                ["id": uuid(), "body": "Release notes for the Mac workspace go out tonight.", "poll_options": NSNull(), "image_count": 0, "scheduled_at": date(-180), "submitted_at": NSNull(), "status": "scheduled"],
                ["id": uuid(), "body": "Which log do you open first in the morning?", "poll_options": ["Following", "Latest", "Trending"], "image_count": 0, "scheduled_at": date(-60 * 26), "submitted_at": NSNull(), "status": "scheduled"],
            ]

            let thread = timeline.first { (replies[$0]?.count ?? 0) > 0 } ?? timeline[0]
            notifications = [
                notification("replied", "jonasw", minutesAgo: 3, commit: thread, unread: true),
                notification("starred", "priya", minutesAgo: 12, commit: own, unread: true, actors: ["priya", "maya", "leom", "samc", "jonasw", "anaribeiro"], events: 9),
                notification("followed", "samc", minutesAgo: 40, commit: nil, unread: true),
                notification("mentioned", "anaribeiro", minutesAgo: 2, commit: timeline[1], unread: true),
                notification("quoted", "anaribeiro", minutesAgo: 2, commit: timeline[1], unread: true),
                notification("approved", "tom", minutesAgo: 300, commit: own, unread: false),
                notification("rejected", "tom", minutesAgo: 900, commit: nil, unread: false, reason: "off-topic"),
                notification("leveled_up", "you", minutesAgo: 2000, commit: nil, unread: false),
            ]

            devices = [
                ["id": uuid(), "name": "Preview Mac", "fingerprint": "SHA256:pR3v1eWm4c0nLyN0tAR3alK3yf1ng3rpr1nt0000", "approved_at": date(60 * 24 * 3), "last_used_at": date(0)],
                ["id": uuid(), "name": "Pixel phone", "fingerprint": "SHA256:anOth3rMad3UpK3yF1ng3rpr1ntF0rTh3Pr3v1ew", "approved_at": date(60 * 24 * 40), "last_used_at": date(60 * 30)],
            ]
        }

        private func image(_ seed: Int, _ width: Int, _ height: Int, _ description: String) -> [String: Any] {
            ["id": "cimg-\(seed)", "width": width, "height": height, "description": description, "url": "https://\(Preview.host)/img/\(seed)/\(width)x\(height).png"]
        }

        private func notification(_ type: String, _ actor: String, minutesAgo: Double, commit: String?, unread: Bool, actors: [String]? = nil, events: Int = 1, reason: String? = nil) -> [String: Any] {
            [
                "id": uuid(), "type": type, "subject_id": nullable(commit), "reason": nullable(reason), "read_at": unread ? NSNull() : date(minutesAgo - 1) as Any,
                "created_at": date(minutesAgo), "actor": user(actor), "actors": (actors ?? [actor]).map(user), "group_id": NSNull(),
                "event_count": events, "actors_count": (actors ?? [actor]).count, "unread_count": unread ? events : 0,
                "commit": nullable(commit.flatMap { commits[$0] }),
            ]
        }

        private func nullable(_ value: Any?) -> Any {
            value ?? NSNull()
        }

        // MARK: Reading

        /// A commit as the API sends it, with its quoted commit and its newest replies for the replier avatars.
        private func full(_ id: String) -> [String: Any]? {
            guard var commit = commits[id] else { return nil }

            if let quoted = commit["quoted_commit_id"] as? String { commit["quoted_commit"] = nullable(commits[quoted]) }
            if let parent = commit["parent_id"] as? String, var parentCommit = commits[parent] {
                parentCommit["reply_preview"] = NSNull()
                commit["parent"] = parentCommit
            }

            let newest = (replies[id] ?? []).suffix(3).reversed().compactMap { commits[$0] }
            commit["reply_preview"] = ["data": newest, "next_cursor": NSNull()]
            commit["replies_count"] = replies[id]?.count ?? 0
            commit["is_pinned"] = id == pinnedId

            return commit
        }

        private func page(_ ids: [String], cursor: String?, size: Int = 20) -> [String: Any] {
            let start = Int(cursor ?? "") ?? 0
            let slice = Array(ids.dropFirst(start).prefix(size))
            let next = start + size < ids.count ? String(start + size) : nil

            return ["data": slice.compactMap(full), "meta": ["next_cursor": nullable(next)]]
        }

        private func visible(_ id: String) -> Bool {
            guard let handle = (commits[id]?["author"] as? [String: Any])?["handle"] as? String else { return false }

            return !muted.contains(handle) && !blocked.contains(handle) && commits[id]?["deleted_at"] is NSNull
        }

        /// Someone the user follows commits about every 45 seconds.
        private func scriptArrivals() {
            guard Date().timeIntervalSince(lastArrivalAt) > 45 else { return }

            lastArrivalAt = Date()
            let author = following.filter { $0 != "tom" }.randomElement() ?? "maya"
            let lines = ["Just merged the thing I said I'd merge last week.", "Coffee, then the migration. In that order.", "Green CI on the first try. Suspicious.", "Reading the Postgres docs for fun again.", "Shipped. Going for a walk."]
            timeline.insert(makeCommit(author, lines.randomElement()!, minutesAgo: 0), at: 0)
        }

        // MARK: Routing

        /// The answer for a workspace route, or nil to leave it to the Remotes preview.
        func respond(method: String, route: String, query: [String: String], json: [String: Any]) -> (Int, Any?)? {
            lock.lock()
            defer { lock.unlock() }

            let parts = route.split(separator: "/").map(String.init)

            switch (method, parts.first ?? "") {
            case ("GET", "log"):
                scriptArrivals()
                let kind = parts.count > 1 ? parts[1] : "following"
                var ids = timeline.filter(visible)

                if kind == "following" {
                    ids = ids.filter { id in following.contains(((commits[id]?["author"] as? [String: Any])?["handle"] as? String) ?? "") || (commits[id]?["author"] as? [String: Any])?["id"] as? String == "u-me" }
                } else if kind == "trending" {
                    var generator = SeededGenerator(seed: UInt64(query["cursor"] == nil ? Int.random(in: 1 ... 9999) : 7))
                    ids = ids.sorted { _, _ in Bool.random(using: &generator) }
                }

                var response = page(ids, cursor: query["cursor"])
                response["log"] = kind
                response["is_ranked"] = kind == "trending"
                response["suggestions"] = []
                return (200, response)
            case ("GET", "starred"):
                return (200, page(starredIds.filter(visible), cursor: query["cursor"]))
            case (_, "commits"):
                return commitRoute(method, parts, query: query, json: json)
            case (_, "users"):
                return userRoute(method, parts, query: query)
            case ("GET", "notifications"):
                if parts.count == 3 {
                    return (200, ["data": [notification("starred", "maya", minutesAgo: 30, commit: timeline[3], unread: false), notification("starred", "leom", minutesAgo: 45, commit: timeline[3], unread: false)], "meta": ["next_cursor": NSNull()]])
                }

                let filter = query["type"] ?? "all"
                let types: [String: [String]] = ["replies": ["replied"], "quotes": ["quoted"], "stars": ["starred"], "mentions": ["mentioned"], "follows": ["followed"], "moderation": ["approved", "rejected"]]
                let shown = filter == "all" ? notifications : notifications.filter { types[filter]?.contains($0["type"] as? String ?? "") == true }
                let response: [String: Any] = ["data": shown, "meta": ["next_cursor": NSNull()], "read_at": date(0)]
                unreadNotifications = 0
                notifications = notifications.map { var item = $0; item["unread_count"] = 0; item["read_at"] = date(0); return item }
                return (200, response)
            case ("GET", "search"):
                return searchRoute(parts.count > 1 ? parts[1] : "", query: query["q"] ?? "")
            case (_, "scheduled-commits"):
                return scheduledRoute(method, parts, json: json)
            case (_, "me"):
                return meRoute(method, parts, json: json)
            default:
                return nil
            }
        }

        private func commitRoute(_ method: String, _ parts: [String], query: [String: String], json: [String: Any]) -> (Int, Any?)? {
            if parts.count == 1, method == "POST" {
                return (201, ["data": full(create(json)) ?? [:]])
            }

            if parts.count == 2, parts[1] == "preview" {
                let id = create(json, keep: false)
                defer { commits[id] = nil }
                return (200, ["data": full(id) ?? [:]])
            }

            guard parts.count >= 2 else { return nil }

            let id = parts[1]

            guard commits[id] != nil else { return (404, ["message": "Not found."]) }

            switch (method, parts.count > 2 ? parts[2] : "") {
            case ("GET", ""):
                var ancestors: [[String: Any]] = []
                var cursor = commits[id]?["parent_id"] as? String
                while let parent = cursor, let commit = full(parent) {
                    ancestors.insert(commit, at: 0)
                    cursor = commits[parent]?["parent_id"] as? String
                }
                return (200, ["data": full(id) ?? [:], "ancestors": ancestors])
            case ("GET", "replies"):
                return (200, page(replies[id] ?? [], cursor: query["cursor"]))
            case ("GET", "related"):
                return (200, ["data": timeline.filter { $0 != id }.shuffled().prefix(3).compactMap(full)])
            case ("POST", "star"), ("DELETE", "star"):
                let starring = method == "POST"
                let stars = commits[id]?["stars_count"] as? Int ?? 0
                commits[id]?["starred"] = starring
                commits[id]?["stars_count"] = max(0, stars + (starring ? 1 : -1))
                if starring { starredIds.insert(id, at: 0) } else { starredIds.removeAll { $0 == id } }
                return (200, ["data": full(id) ?? [:]])
            case ("POST", "pasteis"):
                let pasteis = commits[id]?["pasteis_count"] as? Int ?? 0
                commits[id]?["pasteis_count"] = pasteis + 1
                return (200, ["data": full(id) ?? [:], "pasteis_remaining": 2])
            case ("POST", "poll"):
                if var poll = commits[id]?["poll"] as? [String: Any], var options = poll["options"] as? [[String: Any]] {
                    let votes = [41, 112, 59]
                    for index in options.indices {
                        let voted = options[index]["id"] as? String == json["option"] as? String
                        options[index]["voted"] = voted
                        options[index]["votes_count"] = votes[index % 3] + (voted ? 1 : 0)
                        options[index]["percentage"] = Int((Double(votes[index % 3] + (voted ? 1 : 0)) / 213 * 100).rounded())
                    }
                    poll["options"] = options
                    poll["has_voted"] = true
                    poll["total_votes"] = 213
                    commits[id]?["poll"] = poll
                }
                return (200, ["data": full(id) ?? [:]])
            case ("POST", "reports"):
                return (201, ["message": "Reported."])
            case ("DELETE", ""):
                commits[id]?["deleted_at"] = date(0)
                return (204, nil)
            case ("POST", "restoration"):
                commits[id]?["deleted_at"] = NSNull()
                return (200, ["data": full(id) ?? [:]])
            case ("PUT", "pin"):
                pinnedId = id
                return (200, ["data": full(id) ?? [:]])
            case ("DELETE", "pin"):
                pinnedId = nil
                return (200, ["data": full(id) ?? [:]])
            case ("POST", "translation"):
                return (200, ["translation": ["language": json["language"] ?? "en", "source_language": "pt", "source_name": "Portuguese", "available": true, "body": "(Translated) " + (commits[id]?["body"] as? String ?? "")]])
            default:
                return nil
            }
        }

        private func create(_ json: [String: Any], keep: Bool = true) -> String {
            let body = json["body"] as? String ?? ""
            var extra: [String: Any] = ["status": keep ? "pending" : "approved"]

            if let quoted = json["quoted_commit_id"] as? String {
                extra["quoted_commit_id"] = quoted
            }

            if let poll = json["poll"] as? [String: Any], let options = poll["options"] as? [String] {
                extra["poll"] = ["id": uuid(), "closes_at": date(-60 * 24), "is_closed": false, "has_voted": false, "total_votes": 0, "options": options.enumerated().map { ["id": "new-\($0.offset)", "label": $0.element, "votes_count": 0, "voted": false, "percentage": 0] }]
            }

            if let descriptions = json["image_descriptions"] as? [Any] {
                extra["images"] = descriptions.enumerated().map { image(40 + $0.offset, 1400, 1000, $0.element as? String ?? "") }
            }

            let id = makeCommit("you", body, minutesAgo: 0, parent: json["parent_id"] as? String, extra: extra)

            if keep, json["parent_id"] == nil {
                timeline.insert(id, at: 0)
            }

            return id
        }

        private func userRoute(_ method: String, _ parts: [String], query: [String: String]) -> (Int, Any?)? {
            guard parts.count >= 2 else { return nil }

            let handle = parts[1]

            guard Self.cast[handle] != nil else { return (404, ["message": "Not found."]) }

            switch (method, parts.count > 2 ? parts[2] : "") {
            case ("GET", ""):
                let own = timeline.filter { (commits[$0]?["author"] as? [String: Any])?["handle"] as? String == handle }
                var data = user(handle)
                data["commits_count"] = own.count + 120
                data["followers_count"] = 1204 + handle.count * 31
                data["following_count"] = 188 + handle.count
                let pinned = handle == "you" ? pinnedId.flatMap(full) : own.last.flatMap(full)
                let buckets: [[String: Any]] = (0 ..< 371).map { day in
                    let date = Date(timeIntervalSinceNow: -Double(370 - day) * 86400).formatted(.iso8601.year().month().day())
                    let count = (day * 7 + handle.count) % 11 < 6 ? 0 : (day * 13 + handle.count) % 7
                    return ["date": date, "count": count]
                }
                let badges: [[String: Any]] = [
                    ["id": "init", "name": "init", "description": "Made a first commit.", "icon": NSNull(), "unlocked": true, "progress": 1, "target": 1],
                    ["id": "grep", "name": "grep", "description": "Found something worth starring.", "icon": NSNull(), "unlocked": true, "progress": 10, "target": 10],
                    ["id": "cron", "name": "cron", "description": "Committed seven days in a row.", "icon": NSNull(), "unlocked": true, "progress": 7, "target": 7],
                    ["id": "fsck", "name": "fsck", "description": "Kept a streak through a whole month.", "icon": NSNull(), "unlocked": false, "progress": 12, "target": 30],
                ]
                let activity: [String: Any] = ["scale": "year", "buckets": buckets]
                let achievements: [String: Any] = ["level": 7, "rank": "sysadmin", "xp": 4210, "badges": badges]
                let body: [String: Any] = [
                    "data": data, "is_following": following.contains(handle), "follows_you": handle.count % 2 == 0, "is_muting": muted.contains(handle),
                    "pasteis_received": 7,
                    "activity": activity,
                    "streaks": ["longest": 41, "current": 6],
                    "achievements": achievements,
                    "pinned_commit": nullable(pinned),
                ]
                return (200, body)
            case ("GET", "commits"):
                let ids = (query["replies"] == "1" ? Array(commits.keys).filter { commits[$0]?["parent_id"] is String } : timeline)
                    .filter { (commits[$0]?["author"] as? [String: Any])?["handle"] as? String == handle && visible($0) }
                return (200, page(ids, cursor: query["cursor"]))
            case ("GET", "followers"), ("GET", "following"):
                return (200, ["data": Self.cast.keys.sorted().filter { $0 != handle && $0 != "you" }.prefix(8).map(user), "meta": ["next_cursor": NSNull()]])
            case ("POST", "follow"):
                following.insert(handle)
                return (204, nil)
            case ("DELETE", "follow"):
                following.remove(handle)
                return (204, nil)
            case ("POST", "mute"):
                muted.insert(handle)
                return (200, ["data": user(handle), "is_muting": true])
            case ("DELETE", "mute"):
                muted.remove(handle)
                return (200, ["data": user(handle), "is_muting": false])
            case ("POST", "block"):
                blocked.insert(handle)
                return (200, ["data": user(handle)])
            case ("DELETE", "block"):
                blocked.remove(handle)
                return (200, ["data": user(handle)])
            default:
                return (204, nil)
            }
        }

        private func searchRoute(_ kind: String, query: String) -> (Int, Any?) {
            let term = query.lowercased().trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "@"))

            switch kind {
            case "users", "mentions":
                let handles = Self.cast.keys.sorted().filter { $0 != "you" && !blocked.contains($0) && (term.isEmpty || $0.contains(term) || Self.cast[$0]!.name.lowercased().contains(term)) }
                return (200, kind == "users" ? ["data": handles.prefix(8).map(user)] : ["data": handles.prefix(6).map(user), "organizations": []])
            case "commits":
                guard term.count >= 3 else { return (422, ["message": "The q field must be at least 3 characters."]) }
                let words = term.split(separator: " ")
                let ids = timeline.filter { id in words.contains { (commits[id]?["body"] as? String ?? "").lowercased().contains($0) } }
                return (200, ["data": (ids.isEmpty ? Array(timeline.prefix(4)) : ids).filter(visible).prefix(14).compactMap(full)])
            case "issues":
                guard let number = Int(query) else { return (200, ["issue": NSNull()]) }
                return (200, ["issue": ["number": number, "title": "Mac app: the replies pane forgets its width", "url": "https://example.com/issues/\(number)"]])
            default:
                return (404, ["message": "Not found."])
            }
        }

        private func scheduledRoute(_ method: String, _ parts: [String], json: [String: Any]) -> (Int, Any?) {
            switch (method, parts.count) {
            case ("GET", 1):
                return (200, ["data": scheduled, "meta": ["current_page": 1, "last_page": 1, "total": scheduled.count]])
            case ("POST", 1):
                let item: [String: Any] = ["id": uuid(), "body": json["body"] ?? "", "poll_options": (json["poll"] as? [String: Any])?["options"] ?? NSNull(), "image_count": (json["image_descriptions"] as? [Any])?.count ?? 0, "scheduled_at": json["scheduled_at"] ?? date(-60), "submitted_at": NSNull(), "status": "scheduled"]
                scheduled.append(item)
                return (201, ["data": item])
            case ("DELETE", 2):
                scheduled.removeAll { $0["id"] as? String == parts[1] }
                return (204, nil)
            case ("POST", 3):
                guard let index = scheduled.firstIndex(where: { $0["id"] as? String == parts[1] }) else { return (409, ["message": "This commit was already submitted or canceled. Refresh to see its status."]) }
                let body = scheduled[index]["body"] as? String ?? ""
                timeline.insert(makeCommit("you", body, minutesAgo: 0, extra: ["status": "pending"]), at: 0)
                scheduled[index]["submitted_at"] = date(0)
                scheduled[index]["status"] = "pending"
                scheduled[index]["body"] = NSNull()
                return (200, ["data": scheduled[index]])
            default:
                return (404, ["message": "Not found."])
            }
        }

        private func meRoute(_ method: String, _ parts: [String], json: [String: Any]) -> (Int, Any?)? {
            switch (method, parts.count > 1 ? parts[1] : "") {
            case ("GET", ""):
                return (200, ["data": currentUser(), "unread_notifications_count": unreadNotifications])
            case ("GET", "settings"):
                var data = settings
                data["translation_languages"] = [("de", "German", "Deutsch"), ("en", "English", "English"), ("es", "Spanish", "español"), ("fr", "French", "français"), ("pt", "Portuguese", "português")].map { ["code": $0.0, "name": $0.1, "native_name": $0.2] }
                return (200, ["data": data])
            case ("PUT", "timezone"):
                settings["timezone"] = json["timezone"] ?? NSNull()
                return (200, ["data": currentUser()])
            case ("PUT", "translation-language"):
                settings["translation_language"] = json["translation_language"] ?? NSNull()
                return (200, ["data": currentUser()])
            case ("PUT", "automatic-translation"):
                settings["automatic_translation"] = json["enabled"] ?? true
                return (200, ["data": currentUser()])
            case ("PUT", "lane"):
                lane = json["lane"] ?? json["color"] ?? NSNull()
                return (200, ["data": currentUser()])
            case ("PUT", "pasteis-mode"):
                pasteisMode = json["enabled"] as? Bool ?? json["pasteis_mode"] as? Bool ?? !pasteisMode
                return (200, ["data": currentUser()])
            case ("PUT", "github"):
                return (200, ["data": currentUser()])
            case ("GET", "devices"):
                return (200, ["data": devices])
            case ("DELETE", "devices"):
                devices.removeAll { $0["id"] as? String == parts.last }
                return (204, nil)
            case ("GET", "muted"):
                return (200, ["data": muted.sorted().map(user), "meta": ["next_cursor": NSNull()]])
            case ("GET", "blocked"):
                return (200, ["data": blocked.sorted().map(user), "meta": ["next_cursor": NSNull()]])
            case ("GET", "suggested-users"):
                return (200, ["data": ["samc", "theo", "rosa"].map(user)])
            default:
                return nil
            }
        }

        func currentUser() -> [String: Any] {
            [
                "id": "u-me", "handle": "you", "name": "Preview You", "avatar_url": NSNull(), "html_url": "https://\(Preview.host)/@you", "lane": (lane as? Int) ?? 0,
                "bio": "Building things on /dev/null.", "location": "Lisbon", "website": "https://example.com", "company": NSNull(),
                "created_at": date(60 * 24 * 400), "commits_count": 312, "followers_count": 1204, "following_count": 188,
                "pasteis_mode": pasteisMode, "pasteis_remaining": 3, "preferred_lane": lane, "automatic_lane": 0, "github_synced_at": date(60 * 24),
                "remotes": ["from": "following", "pull_receipts": true, "requests": true, "everyone": true, "unread_count": 0],
            ]
        }
    }

    /// A deterministic shuffle for Trending's pages, so the pages after the first follow the same draw.
    struct SeededGenerator: RandomNumberGenerator {
        private var state: UInt64

        init(seed: UInt64) {
            state = seed &+ 0x9E37_79B9_7F4A_7C15
        }

        mutating func next() -> UInt64 {
            state &+= 0x9E37_79B9_7F4A_7C15
            var value = state
            value = (value ^ (value >> 30)) &* 0xBF58_476D_1CE4_E5B9
            value = (value ^ (value >> 27)) &* 0x94D0_49BB_1331_11EB
            return value ^ (value >> 31)
        }
    }
#endif
