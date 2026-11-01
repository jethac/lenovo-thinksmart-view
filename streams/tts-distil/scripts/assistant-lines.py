#!/usr/bin/env python3
"""Assistant-style lines for the distillation corpus, written for this
project (no third-party text): short and medium replies of the kind the
assistant gives, with times, dates, numbers, prices, percentages, names,
the company and assistant names, and English product names (in katakana for
Japanese, as the assistant writes them).

    assistant-lines.py LANG N SEED > lines.tsv     (id, lang, text)
"""
import random, sys

R = random.Random()

# ---------------------------------------------------------------- English
EN_NAMES = ["Alex", "Priya", "Mei", "Kenji", "Sofia", "Daniel", "Hannah", "Omar", "Yuki", "Grace", "Lucas",
            "Aisha", "Ben", "Chloe", "David", "Elena", "Felix", "Hiro", "Isabel", "James", "Laura", "Marco",
            "Nina", "Oliver", "Rachel", "Sam", "Tom", "Wei", "Zoe", "Ms. Tanaka", "Dr. Patel", "Mr. Chen"]
EN_DAYS = ["Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday", "Sunday", "tomorrow", "today",
           "next Monday", "this Friday"]
EN_MONTHS = ["January", "February", "March", "April", "May", "June", "July", "August", "September",
             "October", "November", "December"]
EN_EVENTS = ["the design review", "a call with the sales team", "the weekly stand-up", "lunch with {n}",
             "the budget meeting", "a one-on-one with {n}", "the product demo", "the quarterly review",
             "an interview", "the onboarding session", "the marketing sync", "a dentist appointment",
             "the all-hands meeting", "a workshop on security", "the board presentation", "a client visit"]
EN_PLACES = ["room four", "room 12", "the main conference room", "the third floor", "the lobby",
             "the Shibuya office", "building B", "the cafeteria", "meeting room A", "the training room"]
EN_APPS = ["Zoom", "Slack", "Teams", "Google Meet", "Outlook", "your calendar", "Notion", "Salesforce"]
EN_CITIES = ["Tokyo", "Osaka", "Shanghai", "Beijing", "Singapore", "London", "New York", "Seoul",
             "San Francisco", "Taipei", "Sydney", "Berlin"]
EN_WEATHER = ["sunny", "cloudy", "rainy", "clear", "windy", "humid", "partly cloudy", "snowy"]


def en_time():
    h = R.randint(1, 12)
    m = R.choice([0, 0, 0, 15, 30, 30, 45, 5, 10, 20, 40, 50])
    style = R.random()
    if style < 0.45:
        return f"{h}:{m:02d}" + R.choice([" AM", " PM", "", " in the morning", " this afternoon"])
    words = {0: "", 15: " fifteen", 30: " thirty", 45: " forty-five", 5: " oh five", 10: " ten",
             20: " twenty", 40: " forty", 50: " fifty"}
    hw = ["one", "two", "three", "four", "five", "six", "seven", "eight", "nine", "ten", "eleven", "twelve"][h - 1]
    if m == 0:
        return R.choice([f"{hw} o'clock", f"{h} o'clock", f"{hw}"])
    if m == 30 and R.random() < 0.3:
        return f"half past {hw}"
    return hw + words[m]


def en_date():
    d = R.randint(1, 28)
    mo = R.choice(EN_MONTHS)
    s = R.random()
    if s < 0.4:
        return f"{mo} {d}"
    if s < 0.7:
        return f"{R.choice(EN_DAYS[:7])}, {mo} {d}"
    suf = "th" if 10 <= d % 100 <= 20 else {1: "st", 2: "nd", 3: "rd"}.get(d % 10, "th")
    return f"the {d}{suf} of {mo}"


def en_line():
    n = R.choice(EN_NAMES)
    ev = R.choice(EN_EVENTS).format(n=R.choice(EN_NAMES))
    t = [
        lambda: f"Your next meeting is {ev} at {en_time()}, in {R.choice(EN_PLACES)}.",
        lambda: f"You have {R.choice(['one', 'two', 'three', 'four', 2, 3, 5])} meetings {R.choice(EN_DAYS)}. The first one starts at {en_time()}.",
        lambda: f"I've moved {ev} to {R.choice(EN_DAYS)} at {en_time()}.",
        lambda: f"Sure. I'll remind you {R.choice(['an hour', 'thirty minutes', '15 minutes', 'ten minutes', 'a day'])} before {ev}.",
        lambda: f"{n} sent you a message on {R.choice(EN_APPS)}: \"{R.choice(['Running five minutes late.', 'Can we push this to tomorrow?', 'The slides are ready.', 'Thanks for your help!', 'Call me when you are free.'])}\"",
        lambda: f"It's {R.randint(-3, 35)} degrees and {R.choice(EN_WEATHER)} in {R.choice(EN_CITIES)} right now.",
        lambda: f"Tomorrow in {R.choice(EN_CITIES)}: a high of {R.randint(5, 34)}, a low of {R.randint(-5, 22)}, and a {R.choice([10, 20, 30, 40, 60, 80])}% chance of rain.",
        lambda: f"The timer is set for {R.choice(['five minutes', '10 minutes', '25 minutes', 'an hour', '90 seconds', 'two and a half hours'])}.",
        lambda: f"That comes to ${R.randint(2, 480)}.{R.randint(0, 99):02d}, including tax.",
        lambda: f"Sales were up {R.randint(2, 40)}.{R.randint(0, 9)}% compared with last quarter.",
        lambda: f"The flight to {R.choice(EN_CITIES)} leaves at {en_time()} on {en_date()}, from gate {R.choice(['12', '34B', '7', '58', '101'])}.",
        lambda: f"Your package should arrive on {en_date()}.",
        lambda: f"Welcome to ai&. I'm Straylight, ai&'s assistant.",
        lambda: f"Hi, I'm Straylight. How can I help?",
        lambda: f"I'm Straylight, the assistant from ai&. {R.choice(['What can I do for you?', 'How can I help today?', 'Ask me anything.'])}",
        lambda: f"ai& has {R.choice(['three', 'four', '12', '25'])} new updates for you {R.choice(EN_DAYS[7:10])}.",
        lambda: f"I couldn't find anything on your calendar for {R.choice(EN_DAYS)}.",
        lambda: f"Good {R.choice(['morning', 'afternoon', 'evening'])}, {n}. {R.choice(['You have a busy day ahead.', 'Your schedule is clear until lunch.', 'There are two new messages for you.', 'It looks like a quiet day.'])}",
        lambda: f"The {R.choice(['report', 'proposal', 'contract', 'invoice', 'presentation'])} is due on {en_date()}.",
        lambda: f"Room {R.randint(1, 30)} is free from {en_time()} to {en_time()}.",
        lambda: f"I've added {R.choice(['milk', 'coffee beans', 'batteries', 'printer paper', 'apples'])} to your shopping list.",
        lambda: f"{n}'s phone number is {R.randint(100, 999)}-{R.randint(100, 999)}-{R.randint(1000, 9999)}.",
        lambda: f"There are {R.randint(2, 60)} people signed up for {ev}.",
        lambda: f"It takes about {R.choice(['20 minutes', 'half an hour', 'an hour and 15 minutes', 'two hours', '45 minutes'])} to get to {R.choice(EN_CITIES)} {R.choice(['by train', 'by car', 'on foot', 'from here'])}.",
        lambda: f"Sorry, I didn't catch that. Could you say it again?",
        lambda: f"I can't reach ai& right now. Please try again in a moment.",
        lambda: f"Please sign in to ai& to continue.",
        lambda: f"OK, I'll join the {R.choice(EN_APPS[:4])} call at {en_time()} and let {n} know.",
        lambda: f"The meeting with {n} was cancelled. Would you like me to find another time?",
        lambda: f"Your {R.choice(['dentist', 'doctor', 'hair', 'car service'])} appointment is on {en_date()} at {en_time()}.",
        lambda: f"The exchange rate is {R.randint(100, 160)}.{R.randint(10, 99)} yen to the dollar.",
        lambda: f"{R.choice(['Battery', 'Storage', 'The download'])} is at {R.randint(5, 99)}%.",
        lambda: f"In {R.choice(EN_CITIES)}, it's {en_time()} right now.",
        lambda: f"Here's a summary of the {R.choice(['email', 'document', 'thread', 'call'])} from {n}: {R.choice(['the launch moves to next week', 'the budget was approved', 'they need two more designers', 'the client liked the demo'])}.",
        lambda: f"You've walked {R.randint(1000, 15000):,} steps today.",
        lambda: f"The next train leaves in {R.randint(2, 19)} minutes, from platform {R.randint(1, 12)}.",
        lambda: f"Call {n} back {R.choice(['after lunch', 'before five', 'tomorrow morning', 'at 3 PM'])}? I can set a reminder.",
    ]
    return R.choice(t)()


# ---------------------------------------------------------------- Japanese
JA_NAMES = ["田中さん", "佐藤さん", "鈴木さん", "高橋さん", "伊藤さん", "渡辺さん", "山本さん", "中村さん",
            "小林さん", "加藤さん", "吉田さん", "山田さん", "松本さん", "井上さん", "木村さん", "林さん",
            "清水さん", "森さん", "池田さん", "橋本さん", "マイクさん", "サラさん", "リーさん", "チェンさん"]
JA_DAYS = ["月曜日", "火曜日", "水曜日", "木曜日", "金曜日", "土曜日", "日曜日", "明日", "今日", "あさって",
           "来週の月曜日", "今週の金曜日"]
JA_EVENTS = ["デザインレビュー", "営業チームとの打ち合わせ", "定例会議", "{n}とのランチ", "予算会議",
             "{n}との面談", "製品デモ", "四半期レビュー", "面接", "新人研修", "マーケティングの打ち合わせ",
             "歯医者の予約", "全体会議", "セキュリティ研修", "役員へのプレゼン", "お客様の訪問"]
JA_PLACES = ["四番会議室", "第2会議室", "大会議室", "3階", "ロビー", "渋谷オフィス", "B棟", "社員食堂",
             "会議室A", "研修室", "オンライン"]
JA_APPS = ["ズーム", "スラック", "チームズ", "グーグルミート", "アウトルック", "カレンダー", "ノーション",
           "LINE", "Zoom"]
JA_CITIES = ["東京", "大阪", "名古屋", "札幌", "福岡", "京都", "横浜", "上海", "北京", "シンガポール",
             "ロンドン", "ニューヨーク", "ソウル", "台北"]
JA_WEATHER = ["晴れ", "くもり", "雨", "晴れのちくもり", "くもり時々雨", "雪"]


def ja_time():
    h = R.randint(1, 12)
    m = R.choice([0, 0, 0, 15, 30, 30, 45, 5, 10, 20, 40, 50])
    pre = R.choice(["午前", "午後", "", "", "朝", "夜"])
    s = R.random()
    if s < 0.55:
        mm = "" if m == 0 else ("半" if m == 30 and R.random() < 0.5 else f"{m}分")
        return f"{pre}{h}時{mm}"
    if s < 0.75:
        return f"{R.randint(8, 21)}:{m:02d}"
    kan = ["一", "二", "三", "四", "五", "六", "七", "八", "九", "十", "十一", "十二"][h - 1]
    return f"{pre}{kan}時" + ("半" if m == 30 else "")


def ja_date():
    mo, d = R.randint(1, 12), R.randint(1, 28)
    return R.choice([f"{mo}月{d}日", f"{mo}月{d}日の{R.choice(JA_DAYS[:7])}", f"{d}日"])


def ja_line():
    n = R.choice(JA_NAMES)
    ev = R.choice(JA_EVENTS).format(n=R.choice(JA_NAMES))
    t = [
        lambda: f"次の予定は、{ja_time()}から{R.choice(JA_PLACES)}で、{ev}です。",
        lambda: f"{R.choice(JA_DAYS)}は会議が{R.randint(1, 6)}件あります。最初の会議は{ja_time()}からです。",
        lambda: f"{ev}を、{R.choice(JA_DAYS)}の{ja_time()}に変更しました。",
        lambda: f"かしこまりました。{ev}の{R.choice(['1時間', '30分', '15分', '10分', '1日'])}前にお知らせします。",
        lambda: f"{n}から{R.choice(JA_APPS)}でメッセージが届いています。「{R.choice(['5分ほど遅れます。', '明日に変更できますか。', '資料の準備ができました。', 'ありがとうございました。', '手が空いたら電話をください。'])}」",
        lambda: f"現在の{R.choice(JA_CITIES)}の天気は{R.choice(JA_WEATHER)}、気温は{R.randint(-3, 35)}度です。",
        lambda: f"明日の{R.choice(JA_CITIES)}は{R.choice(JA_WEATHER)}で、最高気温は{R.randint(5, 34)}度、降水確率は{R.choice([10, 20, 30, 40, 60, 80])}パーセントです。",
        lambda: f"タイマーを{R.choice(['5分', '10分', '25分', '1時間', '90秒', '3分'])}にセットしました。",
        lambda: f"合計で{R.randint(2, 98)}{R.choice(['0', '00', '50', '80'])}円です。",
        lambda: f"売上は前の四半期に比べて{R.randint(2, 40)}パーセント増えました。",
        lambda: f"{R.choice(JA_CITIES)}行きの便は、{ja_date()}の{ja_time()}に出発します。",
        lambda: f"荷物は{ja_date()}に届く予定です。",
        lambda: "ai&へようこそ。ai&のアシスタント、ストレイライトです。",
        lambda: "こんにちは、ストレイライトです。ご用件をどうぞ。",
        lambda: f"ai&のアシスタント、ストレイライトです。{R.choice(['何をお手伝いしましょうか。', 'ご用件をどうぞ。', 'なんでも聞いてください。'])}",
        lambda: f"{R.choice(JA_DAYS)}の予定は、カレンダーに見つかりませんでした。",
        lambda: f"{R.choice(['おはようございます', 'こんにちは', 'こんばんは'])}、{n}。{R.choice(['今日は忙しい一日になりそうです。', 'お昼まで予定は空いています。', '新しいメッセージが2件あります。', '今日は落ち着いた一日です。'])}",
        lambda: f"{R.choice(['報告書', '企画書', '契約書', '請求書', 'プレゼン資料'])}の締め切りは{ja_date()}です。",
        lambda: f"{R.choice(JA_PLACES[:4])}は{ja_time()}から空いています。",
        lambda: f"買い物リストに{R.choice(['牛乳', 'コーヒー豆', '電池', 'コピー用紙', 'りんご', 'トイレットペーパー'])}を追加しました。",
        lambda: f"{ev}には{R.randint(2, 60)}人が参加予定です。",
        lambda: f"{R.choice(JA_CITIES)}までは{R.choice(['電車で', '車で', '歩いて', 'ここから'])}{R.choice(['20分', '30分', '1時間15分', '2時間', '45分'])}ほどかかります。",
        lambda: "すみません、聞き取れませんでした。もう一度お願いします。",
        lambda: "今はai&に接続できません。しばらくしてからもう一度お試しください。",
        lambda: "続けるには、ai&にサインインしてください。",
        lambda: f"わかりました。{ja_time()}の{R.choice(JA_APPS[:4])}会議に参加して、{n}にお伝えします。",
        lambda: f"{n}との打ち合わせはキャンセルになりました。別の時間を探しましょうか。",
        lambda: f"{R.choice(['歯医者', '病院', '美容院', '車の点検'])}の予約は{ja_date()}の{ja_time()}です。",
        lambda: f"現在の為替レートは、1ドル{R.randint(100, 160)}円{R.randint(10, 99)}銭です。",
        lambda: f"{R.choice(['バッテリー', 'ストレージ', 'ダウンロード'])}は{R.randint(5, 99)}パーセントです。",
        lambda: f"{R.choice(JA_CITIES)}は今、{ja_time()}です。",
        lambda: f"{n}からの{R.choice(['メール', '資料', 'チャット', '電話'])}の要点です。{R.choice(['リリースは来週に延期になりました。', '予算が承認されました。', 'デザイナーがあと2人必要です。', 'お客様はデモを気に入ってくれました。'])}",
        lambda: f"今日は{R.randint(1000, 15000)}歩、歩きました。",
        lambda: f"次の電車は{R.randint(2, 19)}分後に、{R.randint(1, 12)}番線から出発します。",
        lambda: f"{R.choice(['お昼のあと', '5時までに', '明日の朝', '午後3時に'])}{n}に折り返し電話しますか。リマインダーを設定できます。",
        lambda: f"{R.choice(['マーケティング', 'エンジニアリング', 'デザイン', 'セールス'])}チームの{R.choice(['ミーティング', 'ワークショップ', 'レビュー'])}は{ja_date()}です。",
        lambda: f"{R.choice(['スマートフォン', 'パソコン', 'タブレット', 'プリンター'])}の{R.choice(['アップデート', 'バックアップ', 'セットアップ'])}が完了しました。",
    ]
    return R.choice(t)()


# ---------------------------------------------------------------- Mandarin
ZH_NAMES = ["王经理", "李老师", "张伟", "刘洋", "陈静", "杨帆", "赵敏", "黄磊", "周婷", "吴刚", "徐丽",
            "孙浩", "马丽", "朱明", "胡军", "林小姐", "何先生", "高总", "Mike", "Sarah"]
ZH_DAYS = ["星期一", "星期二", "星期三", "星期四", "星期五", "星期六", "星期天", "明天", "今天", "后天",
           "下周一", "这周五"]
ZH_EVENTS = ["设计评审", "和销售团队的会议", "每周例会", "和{n}吃午饭", "预算会议", "和{n}的一对一面谈",
             "产品演示", "季度评审", "面试", "新员工培训", "市场部的会议", "牙医预约", "全体员工大会",
             "安全培训", "董事会汇报", "客户拜访"]
ZH_PLACES = ["四号会议室", "12号会议室", "大会议室", "三楼", "大厅", "上海办公室", "B座", "食堂",
             "A会议室", "培训室"]
ZH_APPS = ["Zoom", "微信", "钉钉", "飞书", "Teams", "日历", "邮件"]
ZH_CITIES = ["北京", "上海", "广州", "深圳", "杭州", "成都", "东京", "大阪", "新加坡", "伦敦", "纽约",
             "首尔", "台北", "香港"]
ZH_WEATHER = ["晴", "多云", "小雨", "阴", "晴转多云", "阵雨", "小雪"]


def zh_time():
    h = R.randint(1, 12)
    m = R.choice([0, 0, 0, 15, 30, 30, 45, 5, 10, 20, 40, 50])
    pre = R.choice(["上午", "下午", "晚上", "", "早上"])
    s = R.random()
    if s < 0.6:
        mm = "" if m == 0 else ("半" if m == 30 and R.random() < 0.6 else f"{m}分")
        return f"{pre}{h}点{mm}"
    if s < 0.75:
        return f"{R.randint(8, 21)}:{m:02d}"
    kan = ["一", "两", "三", "四", "五", "六", "七", "八", "九", "十", "十一", "十二"][h - 1]
    return f"{pre}{kan}点" + ("半" if m == 30 else "")


def zh_date():
    mo, d = R.randint(1, 12), R.randint(1, 28)
    return R.choice([f"{mo}月{d}日", f"{mo}月{d}号", f"{mo}月{d}日{R.choice(ZH_DAYS[:7])}", f"{d}号"])


def zh_line():
    n = R.choice(ZH_NAMES)
    ev = R.choice(ZH_EVENTS).format(n=R.choice(ZH_NAMES))
    t = [
        lambda: f"你的下一个会议是{ev}，在{zh_time()}，{R.choice(ZH_PLACES)}。",
        lambda: f"你{R.choice(ZH_DAYS)}有{R.choice(['一', '两', '三', '四', '5', '6'])}个会议，第一个{zh_time()}开始。",
        lambda: f"好的，我已经把{ev}改到{R.choice(ZH_DAYS)}{zh_time()}。",
        lambda: f"好的，我会在{ev}开始前{R.choice(['一个小时', '半个小时', '15分钟', '十分钟', '一天'])}提醒你。",
        lambda: f"{n}在{R.choice(ZH_APPS)}上给你发了一条消息：“{R.choice(['我会晚到五分钟。', '能改到明天吗？', '资料已经准备好了。', '谢谢你的帮助！', '有空给我回个电话。'])}”",
        lambda: f"{R.choice(ZH_CITIES)}现在{R.choice(ZH_WEATHER)}，气温{R.randint(-3, 35)}度。",
        lambda: f"明天{R.choice(ZH_CITIES)}{R.choice(ZH_WEATHER)}，最高气温{R.randint(5, 34)}度，降水概率百分之{R.choice([10, 20, 30, 40, 60, 80])}。",
        lambda: f"计时器已经设好了，{R.choice(['五分钟', '10分钟', '25分钟', '一个小时', '90秒', '三分钟'])}。",
        lambda: f"一共是{R.randint(2, 980)}块{R.randint(1, 9)}毛。",
        lambda: f"总共{R.randint(12, 4800)}元，含税。",
        lambda: f"和上个季度相比，销售额增长了{R.randint(2, 40)}.{R.randint(0, 9)}%。",
        lambda: f"飞往{R.choice(ZH_CITIES)}的航班{zh_date()}{zh_time()}起飞，在{R.randint(1, 60)}号登机口。",
        lambda: f"你的快递预计{zh_date()}送达。",
        lambda: "欢迎来到ai&。我是ai&的助手，Straylight。",
        lambda: "你好，我是你的语音助手。有什么可以帮你的吗？",
        lambda: f"我是ai&的助手Straylight。{R.choice(['有什么可以帮你的？', '请问需要什么帮助？', '有问题尽管问我。'])}",
        lambda: f"你{R.choice(ZH_DAYS)}的日历上没有安排。",
        lambda: f"{R.choice(['早上好', '下午好', '晚上好'])}，{n}。{R.choice(['今天会比较忙。', '中午之前没有安排。', '你有两条新消息。', '今天比较轻松。'])}",
        lambda: f"{R.choice(['报告', '方案', '合同', '发票', '演示文稿'])}的截止日期是{zh_date()}。",
        lambda: f"{R.choice(ZH_PLACES[:4])}{zh_time()}到{zh_time()}是空的。",
        lambda: f"我已经把{R.choice(['牛奶', '咖啡豆', '电池', '打印纸', '苹果', '纸巾'])}加到购物清单里了。",
        lambda: f"{ev}一共有{R.randint(2, 60)}个人报名。",
        lambda: f"{R.choice(['坐地铁', '开车', '走路', '从这里'])}去{R.choice(ZH_CITIES)}大概要{R.choice(['20分钟', '半个小时', '一个小时', '两个小时', '45分钟'])}。",
        lambda: "不好意思，我没听清楚，请再说一遍。",
        lambda: "现在连不上ai&，请稍后再试。",
        lambda: "请先登录ai&再继续。",
        lambda: f"好的，我会参加{zh_time()}的{R.choice(['Zoom', '飞书', '钉钉', 'Teams'])}会议，并告诉{n}。",
        lambda: f"和{n}的会议取消了。要我帮你找别的时间吗？",
        lambda: f"你的{R.choice(['牙医', '体检', '理发', '车辆保养'])}预约在{zh_date()}{zh_time()}。",
        lambda: f"现在的汇率是一美元兑{R.randint(6, 7)}.{R.randint(10, 99)}元人民币。",
        lambda: f"{R.choice(['电池电量', '存储空间', '下载进度'])}是百分之{R.randint(5, 99)}。",
        lambda: f"{R.choice(ZH_CITIES)}现在是{zh_time()}。",
        lambda: f"这是{n}的{R.choice(['邮件', '文件', '聊天记录', '电话'])}摘要：{R.choice(['发布推迟到下周。', '预算已经批准了。', '还需要两名设计师。', '客户很喜欢这次演示。'])}",
        lambda: f"你今天走了{R.randint(1000, 15000)}步。",
        lambda: f"下一班地铁{R.randint(2, 19)}分钟后从{R.randint(1, 12)}号站台出发。",
        lambda: f"要不要{R.choice(['午饭后', '五点以前', '明天早上', '下午三点'])}给{n}回电话？我可以帮你设个提醒。",
        lambda: f"{R.choice(['marketing', '产品', '设计', '销售'])}团队的{R.choice(['会议', '培训', '评审'])}在{zh_date()}。",
        lambda: f"你的{R.choice(['手机', '电脑', '平板', '打印机'])}{R.choice(['更新', '备份', '设置'])}已经完成了。",
    ]
    return R.choice(t)()


def main():
    lang, n, seed = sys.argv[1], int(sys.argv[2]), int(sys.argv[3])
    R.seed(seed)
    gen = {"en": en_line, "ja": ja_line, "zh": zh_line}[lang]
    seen, out, tries = set(), [], 0
    while len(out) < n and tries < n * 50:
        tries += 1
        s = gen()
        if s in seen:
            continue
        seen.add(s)
        out.append(s)
    for i, s in enumerate(out):
        print(f"{lang}-as-{i:05d}\t{lang}\t{s}")


main()
