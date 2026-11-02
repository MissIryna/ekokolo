# frozen_string_literal: true

# Коло добрих екосправ — API
# 101 курінь УСП «Карпатські Вовки»
#
# Код Рою — спільний секрет: без нього ні прочитати, ні записати поступ.
# Масив справ зливається на стороні бази, тож два пристрої одного новака
# не затирають одне одного.

require "sinatra/base"
require "sequel"
require "json"
require "securerandom"

DB = Sequel.connect(
  ENV.fetch("DATABASE_URL"),
  max_connections: Integer(ENV.fetch("DB_POOL", "8"))
)
DB.extension :pg_json

class Ekokolo < Sinatra::Base
  ORIGINS = ENV
            .fetch("ALLOWED_ORIGINS", "https://ekokolo.pp.ua,http://localhost:8000")
            .split(",").map(&:strip).reject(&:empty?).freeze

  # Без I, O, S, 0, 1 — щоб діти не плутали на слух і на вигляд.
  ALPHABET  = "ACEFHJKLMNPRTUVWXY34789"
  CODE_LEN  = 4
  MAX_DEEDS = 200
  DEED_RE   = /\Ad\d{1,3}\z/
  MAX_BODY  = 64 * 1024

  configure do
    set :show_exceptions, false
    set :raise_errors,    false
    set :logging,         true
  end

  helpers do
    def json(obj, status_code = 200)
      content_type :json
      status status_code
      JSON.generate(obj)
    end

    def fail!(status_code, msg)
      halt status_code, { "Content-Type" => "application/json" },
           JSON.generate(error: msg)
    end

    def payload
      @payload ||= begin
        raw = request.body.read(MAX_BODY).to_s
        raw.empty? ? {} : JSON.parse(raw)
      rescue JSON::ParserError
        fail!(400, "кривий JSON")
      end
    end

    def clean(value, max = 24)
      value.to_s.strip[0, max].to_s
    end

    def nick_key(value)
      clean(value).downcase
    end

    def deed_list(value)
      fail!(422, "codes має бути масивом") unless value.nil? || value.is_a?(Array)
      list = Array(value).map(&:to_s).uniq.select { |c| c.match?(DEED_RE) }
      fail!(422, "забагато справ") if list.size > MAX_DEEDS
      list
    end

    def roi_by_code!(code)
      row = DB[:roi].where(code: clean(code, CODE_LEN).upcase).first
      fail!(404, "такого коду немає") unless row
      row
    end

    def fresh_code
      Array.new(CODE_LEN) { ALPHABET[SecureRandom.random_number(ALPHABET.size)] }.join
    end
  end

  before do
    origin = request.env["HTTP_ORIGIN"]
    headers "Vary" => "Origin"
    headers "Access-Control-Allow-Origin" => origin if origin && ORIGINS.include?(origin)
  end

  options "/api/*" do
    headers "Access-Control-Allow-Methods" => "GET, POST, OPTIONS",
            "Access-Control-Allow-Headers" => "Content-Type",
            "Access-Control-Max-Age"       => "86400"
    status 204
    ""
  end

  # ──────────────── Рої ────────────────

  # Виховник створює Рій і отримує код для новаків.
  post "/api/roi" do
    name = clean(payload["name"])
    fail!(422, "потрібна назва Рою") if name.empty?
    test = payload["test"] ? true : false

    8.times do
      begin
        row = DB[:roi]
              .returning(:id, :name, :code)
              .insert(name: name, code: fresh_code, test: test)
              .first
        return json(row)
      rescue Sequel::UniqueConstraintViolation
        next
      end
    end
    fail!(503, "не вдалося підібрати вільний код")
  end

  # Новак перевіряє код, який дав виховник.
  get "/api/roi/:code" do
    row = roi_by_code!(params[:code])
    json(id: row[:id], name: row[:name], code: row[:code])
  end

  # ──────────────── поступ ────────────────

  # Прочитати свій поступ. Рядка не створює.
  get "/api/progress" do
    roi  = roi_by_code!(params[:code])
    nick = clean(params[:nick])
    fail!(422, "потрібне прізвисько") if nick.empty?

    row = DB[:novak].where(roi_id: roi[:id], nick_key: nick_key(nick)).first
    json(done: row ? row[:codes].to_a : [])
  end

  # Записати поступ. Зливається з тим, що вже є.
  post "/api/progress" do
    roi  = roi_by_code!(payload["code"])
    nick = clean(payload["nick"])
    fail!(422, "потрібне прізвисько") if nick.empty?
    list = deed_list(payload["codes"])

    row = DB.fetch(<<~SQL, roi[:id], nick, nick_key(nick), JSON.generate(list)).first
      insert into novak (roi_id, nick, nick_key, codes)
      values (?, ?, ?, ?::jsonb)
      on conflict (roi_id, nick_key) do update
         set codes = (
               select coalesce(jsonb_agg(distinct e), '[]'::jsonb)
               from jsonb_array_elements(novak.codes || excluded.codes) e
             ),
             nick       = excluded.nick,
             updated_at = now()
      returning codes
    SQL

    json(done: row[:codes].to_a)
  end

  # ──────────────── табло ────────────────

  get "/api/board" do
    json(DB[:board].order(Sequel.desc(:sum), :grp).all)
  end

  # ──────────────── службове ────────────────

  get "/api/health" do
    DB.fetch("select 1").first
    json(ok: true)
  end

  # Sinatra кличе цей блок на будь-який 404, зокрема після fail!(404, …),
  # тож власне повідомлення не затираємо.
  not_found do
    content_type :json
    next body unless body.empty?
    JSON.generate(error: "немає такого шляху")
  end

  error do
    e = env["sinatra.error"]
    logger.error("#{e.class}: #{e.message}") if respond_to?(:logger) && logger
    content_type :json
    status 500
    JSON.generate(error: "щось зламалося на сервері")
  end

  run! if app_file == $PROGRAM_NAME
end
