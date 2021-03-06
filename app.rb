require 'bundler/setup'
Bundler.require
require 'sinatra/json'
require 'sinatra/reloader' if development?
require "./models"
require "date"
require 'bcrypt'
enable :sessions
require "pry"
require "uri"
require "./models"

SLACK＿API_BASE = "https://slack.com/api/";

# アプリ固有のトークン
# レガシートークンは使わない
CLIENT_ID = "448569467826.451820329812"
CLIENT_SECRET = "94835dfd6993840bfc5b8bb6bcc970aa"

# レガシートークン使いたくない

before do
	@client_id = CLIENT_ID
	unless 
		request.path.include?('/signin') ||
		request.path.include?('/create_mokmok') || 
		request.path.include?('/event_catch_json') ||
		request.path.include?('/event_catch_post') ||
		request.path.include?('/signin_with_slack') ||
		request.path.include?('/mokmoks/setup')
		
		unless session[:user].nil?
			@current_user = session[:user]
    else
    	redirect "/signin"
    end  	
  end
end

def postRequest(url, content)
	res = Net::HTTP.post_form(URI.parse(url),content)
	return res
end

def openDialog(dialog, trigger_id, bot_token)
	res = Net::HTTP.post_form(URI.parse("https://slack.com/api/dialog.open?token=#{bot_token}&dialog=#{dialog.to_json}&trigger_id=#{trigger_id}&pretty=1"),{trigger_id: trigger_id, dialog: dialog.to_json, token: bot_token})
	return res
end

def exportMemberIds(oauth_token,channel)
	url = SLACK＿API_BASE + "channels.info?token=" + oauth_token + "&channel=" + channel + "&pretty=1"
	res = Net::HTTP.get(URI.parse(url))
	res = JSON.parse(res)
	return res['channel']['members']
end

def exportMemberInfo(oauth_token,member_id)
	url = SLACK＿API_BASE + "users.info?token=" + oauth_token + "&user=" + member_id + "&pretty=1"
	res = Net::HTTP.get(URI.parse(url))
	res = JSON.parse(res)["user"]
	return res
end

def exportAllChannelNames(oauth_token)
	channels = exportChannelList(oauth_token)
	names = {}
	channels.each {|channel|
		names[channel["id"]] = channel["name"]
	}
	return names;
end

def exportMemberName(oauth_token, member_id)
	res = exportMemberInfo(oauth_token, member_id)
	return res["profile"]["real_name"]
end

def exportChannelList(oauth_token)
	url = "https://slack.com/api/channels.list?token=#{oauth_token}&pretty=1"
	res = JSON.parse(Net::HTTP.get(URI.parse(url)))
	return res["channels"]
end

post '/create_mokmok' do 
	trigger_id = params[:trigger_id]
	dates = []
	today = Date.today
	(0..30).each{ |num|
		dates << {label: today + num, value: today + num}
	}
	times = []
	(0..47).each{ |num|
		time = "#{num/2}:"
		if num % 2 == 1
			time = time + "30"
		else
			time = time + "00"
		end
		times << {label: time, value: time}
	}
	dialog =
	{
		callback_id: "new_mokmok",
		title: "New MokMok",
		submit_label: "Request",
		state: "Limo",
		elements: [
			{
				label: "Title",
				name: "title",
				type: "text",
				subtype: "email",
				placeholder: "WEBS MokMok"
				
			},
			{
				label: "Place",
				name: "place",
				type: "text",
				placeholder: "sibuya"
				
			},
			{
				label: "Date",
				type: "select",
				name: "date",
				options: dates
			},
			{
				label: "Start Time",
				type: "select",
				name: "start_time",
				options: times
				
			},
			{
				label: "Finish Time",
				type: "select",
				name: "finish_time",
				options: times
			},
		]
	}
	bot_token = exportBotAccessToken(params[:team_id])
	res = openDialog(dialog,trigger_id, bot_token)
	return
end

# イベントサブスクリプションのイベント
# https://api.slack.com/apps/AD4E4GT8B/event-subscriptions?
post '/event_catch_json' do
	json_data = JSON.parse(request.body.read)

	if json_data["challenge"]
		res = {challenge: json_data["challenge"]}
	end

	if json_data["event"]
		event_type = json_data["event"]["type"]
	end

	if event_type == "app_mention"
		exportCode()
	end
	json res
end

# もくもく会作成押した時
# もくもく会参加ボタン押した時
# インタラクティブコンポーネントのイベント
# https://api.slack.com/apps/AD4E4GT8B/interactive-messages?
# ボタンなど押した時に最初に呼ばれるところ
post '/event_catch_post' do
	payload = JSON.parse(params["payload"])
	
	type = payload["type"]
	# ボタンが押された時
	if type == "interactive_message"
		if payload["callback_id"] == "participate_mokmok"
			participateMokmok(payload)
		end
		
	# dialogが送られた時
	elsif type == "dialog_submission"
		if payload["callback_id"] == "new_mokmok"
			createNewMokmok(payload)
		end
	end


	return
end

def createNewMokmok(payload)
	
	team_id = payload["team"]["id"]
	channel_id = payload["channel"]["id"]
	user_id = payload["user"]["id"]
	title = payload["submission"]["title"]
	date = payload["submission"]["date"]
	place = payload["submission"]["place"]
	start_date = DateTime.parse(date + "T" + payload["submission"]["start_time"])
	finish_date = DateTime.parse(date + "T" + payload["submission"]["finish_time"])
	
	# dbにほぞんする
	mokmok = Mokmok.create(
		title: title,
		start_date: start_date,
		finish_date: finish_date,
		creator_id: user_id,
		channel_id: channel_id,
		team_id: team_id,
		place: place
	)
	
	# channelにもくもく会できました&参加ボタン付きメッセを送る
	
	bot_token = exportBotAccessToken(team_id)
	participate_btn =
	{
		channel: channel_id,
		token: bot_token,
		text: "もくもく会が作成されました",
		attachments: 
		[
				{
						fallback: "You are unable to choose a game",
						callback_id: "participate_mokmok",
						color: "#3AA3E3",
						attachment_type: "default",
						title: title,
						text: "#{start_date.strftime("%m/%d %H:%M")}~#{finish_date.strftime("%H:%M")} in #{place}" ,
						actions: [
								{
										name: "participate",
										text: "参加する",
										type: "button",
										value: mokmok.id
								},
						]
				},
				{
					title: "詳細URL",
					text: "https://mokmok-aldytsukasa.c9users.io/mokmoks/view/#{mokmok.id}"
				}
		].to_json
	}
	
	talkWithChannelId(participate_btn, channel_id, team_id)
end

def participateMokmok(payload)
	mokmok_id = payload["actions"][0]["value"]
	user_id = payload["user"]["id"]
	if ParticipateUser.find_by(user_id: user_id, mokmok_id: mokmok_id).nil?
		ParticipateUser.create(
			mokmok_id: mokmok_id,
			user_id: user_id
		)
		team_id = payload["tean"]["id"]
		mokmok = Mokmok.find(mokmok_id)
		bot_token = exportBotAccessToken(team_id)
		user_name = exportMemberName(bot_token, user_id)
		res = talkWithChannelId({text: "【#{mokmok.title} @#{mokmok.place}】に#{user_name}さんが参加しました\n詳細:https://mokmok-aldytsukasa.c9users.io/mokmoks/view/#{mokmok.id}"}, mokmok.channel_id, team_id)
	end
end

# https://api.slack.com/methods/chat.postMessage
def talkWithChannelId(content, channel_id, team_id)
	bot_token  = exportBotAccessToken(team_id)
	url = "https://slack.com/api/chat.postMessage"
	content[:channel] = channel_id
	content[:token] = bot_token
	res = postRequest(url, content)
	return res
end

get '/' do
	@mokmoks = Mokmok.all
	erb :index
end

get '/mokmoks/view/:id' do
	@mokmok = Mokmok.find(params[:id])
	bot_token = exportBotAccessToken(@mokmok.team_id)
	@creator = exportMemberInfo(bot_token, @mokmok.creator_id)["profile"]
	@participate_users = []
	@mokmok.participate_users.each {|participate_user|
		@participate_users << exportMemberInfo(bot_token, participate_user.user_id)["profile"]
	}
	erb :mokmok_ditail
end

get '/mokmoks' do
	team_id = session[:team]["id"]
	@mokmoks_created = Mokmok.where("team_id = ? AND creator_id = ?",team_id, session[:user]["id"])
	
	@mokmoks = Mokmok.where("team_id = ? AND channel_id IN (?)", team_id, session[:channels])
	bot_token = exportBotAccessToken(team_id)
	@creators = {}
	@participate_users = {}
	@mokmoks.each{|mokmok|
			@creators[mokmok.id] = exportMemberInfo(bot_token, mokmok.creator_id)["profile"]
			mokmok.participate_users.each {|participate_user|
				@participate_users[mokmok.id] = {}
				@participate_users [mokmok.id][participate_user.user_id] =  exportMemberInfo(bot_token, participate_user.user_id)["profile"]
			}
	}
	@channels = exportAllChannelNames(bot_token)
	erb :mokmoks
end

get '/signin' do
	erb :signin
end

get '/mokmoks/participate/:mokmok_id' do
	mokmok_id = params[:mokmok_id]
	user_id = session[:user]["id"]
	redirect_url = params[:redirect_url]
	if ParticipateUser.find_by(user_id: user_id, mokmok_id: mokmok_id).nil?
		ParticipateUser.create(
			mokmok_id: mokmok_id,
			user_id: user_id
		)
		
	end
	redirect redirect_url
end

get '/signin_with_slack' do
	url = "https://slack.com/api/oauth.access?client_id=#{CLIENT_ID}&client_secret=#{CLIENT_SECRET}&code=#{params[:code]}&pretty=1"
	res = Net::HTTP.get(URI.parse(url))
	data = JSON.parse(res)
	data = exportUserInfoWithAccessToken(data["access_token"])
	data = symbolize_keys(data)
	session[:user] = data[:user]
	session[:team] = data[:team]
	session[:channels] = getJoinedChannelIds(session[:user]["id"])
	redirect '/mokmoks'
end

def exportUserInfoWithAccessToken(access_token)
	url = "https://slack.com/api/users.identity?token=#{access_token}"
	res = Net::HTTP.get(URI.parse(url))
	return JSON.parse(res)
end

def getJoinedChannelIds(member_id) 
	url = "https://slack.com/api/channels.list?token=#{BOT_TOKEN}&pretty=1"
	res = JSON.parse(Net::HTTP.get(URI.parse(url)))
	channels = res["channels"]
	channel_ids = []
	channels.each{|channel| 
		member_ids = channel["members"]
		if member_ids.include?(member_id)
			channel_ids << channel["id"]
		end
	}
	return channel_ids
end

def symbolize_keys(hash)
  hash.map{|k,v| [k.to_sym, v] }.to_h
end

get "/mokmoks/edit/:id" do
	@mokmok = Mokmok.find(params[:id])
	@start_day = @mokmok.start_date.strftime("%Y-%m-%d")
	@times = []
	@start_time = @mokmok.start_date.strftime("%H:%M")
	@finish_time = @mokmok.finish_date.strftime("%H:%M")
	(0..47).each{ |num|
		time = "#{num/2}:"
		if num % 2 == 1
			time = time + "30"
		else
			time = time + "00"
		end
		@times << time
	}
	erb :mokmok_edit
end

post "/mokmoks/edit/:id" do
	id = params[:id]
	date = params[:date]
	start_date = DateTime.parse(date + " " + params[:start_time])
	finish_date = DateTime.parse(date + " " + params[:finish_time])
	@mokmok = Mokmok.find(params[:id])
	@mokmok.update({title: params[:title], description: params[:description], start_date: start_date, finish_date: finish_date})
	redirect "/mokmoks/view/#{id}"
end

get "/mokmoks/setup" do
	data = fetchWorkspaceData(params[:code])
	unless Workspace.find_by(team_id: data["team_id"])
		Workspace.create(
			access_token: data["access_token"],
			scope: data["scope"],
			team_name: data["team_name"],
			team_id: data["team_id"],
			bot_user_id: data["bot"]["bot_user_id"],
			bot_access_token: data["bot"]["bot_access_token"]
		)
	end
	redirect "/signin"
end


def fetchWorkspaceData(code) 
	url = "https://slack.com/api/oauth.access?client_id=#{CLIENT_ID}&client_secret=#{CLIENT_SECRET}&code=#{code}&redirect_uri=https://mokmok-aldytsukasa.c9users.io/mokmoks/setup"
	res = JSON.parse(Net::HTTP.get(URI.parse(url)))
	return res
end

def exportBotAccessToken(team_id)
	workspace = Workspace.find_by(team_id: team_id)
	return workspace.bot_access_token
end

def exportCode()
	scope = "chat:write:bot bot commands users:read"
	redirect_url = "https://mokmok-aldytsukasa.c9users.io/mokmoks/setup"
	url = "https://slack.com/oauth/authorize?client_id=#{CLIENT_ID}&scope=#{scope}&redirect_uri=#{redirect_url}"
	res = Net::HTTP.get(URI.parse(url))
end