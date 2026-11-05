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
  KEY_LEN   = 8
  MAX_DEEDS = 200
  DEED_RE   = /\Ad\d{1,3}\z/
  MAX_BODY  = 64 * 1024
  MARKS     = %w[ok hard fix].freeze

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

    def fresh_code(len = CODE_LEN)
      Array.new(len) { ALPHABET[SecureRandom.random_number(ALPHABET.size)] }.join
    end

    def roi_by_key!(key)
      key = clean(key, KEY_LEN).upcase
      row = key.size == KEY_LEN && DB[:roi].where(lead_key: key).first
      fail!(404, "такого ключа немає") unless row
      row
    end

    def novak_in!(roi, id)
      row = DB[:novak].where(roi_id: roi[:id], id: Integer(id.to_s, exception: false)).first
      fail!(404, "такого новака в Рої немає") unless row
      row
    end

    # Рядок новака з урахуванням злиття: записи під злитим прізвиськом
    # ідуть у той, куди його злили.
    def novak_row(roi, nick)
      row = DB[:novak].where(roi_id: roi[:id], nick_key: nick_key(nick)).first
      row && row[:alias_of] ? DB[:novak].where(id: row[:alias_of]).first : row
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

  # Виховник створює Рій і отримує код для новаків і ключ для себе.
  post "/api/roi" do
    name = clean(payload["name"])
    fail!(422, "потрібна назва Рою") if name.empty?
    test = payload["test"] ? true : false

    8.times do
      begin
        row = DB[:roi]
              .returning(:id, :name, :code, :test, :lead_key)
              .insert(name: name, code: fresh_code, lead_key: fresh_code(KEY_LEN), test: test)
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
    json(id: row[:id], name: row[:name], code: row[:code], test: row[:test])
  end

  # ──────────────── поступ ────────────────

  # Прочитати свій поступ. Рядка не створює.
  get "/api/progress" do
    roi  = roi_by_code!(params[:code])
    nick = clean(params[:nick])
    fail!(422, "потрібне прізвисько") if nick.empty?

    row = novak_row(roi, nick)
    json(done: row ? row[:codes].to_a : [])
  end

  # Записати поступ. Зливається з тим, що вже є.
  post "/api/progress" do
    roi  = roi_by_code!(payload["code"])
    nick = clean(payload["nick"])
    fail!(422, "потрібне прізвисько") if nick.empty?
    list = deed_list(payload["codes"])

    # Порожній запис рядка не створює: інакше виховник, що щойно
    # завів Рій, і дитина без жодної справи рахувалися б новаками.
    row = novak_row(roi, nick)
    return json(done: row ? row[:codes].to_a : []) if list.empty?

    if row && row[:nick_key] != nick_key(nick)
      row = DB.fetch(<<~SQL, JSON.generate(list), row[:id]).first
        update novak
           set codes = (
                 select coalesce(jsonb_agg(distinct e), '[]'::jsonb)
                 from jsonb_array_elements(codes || ?::jsonb) e
               ),
               updated_at = now()
         where id = ?
        returning codes
      SQL
      return json(done: row[:codes].to_a)
    end

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

  # ──────────────── виховник ────────────────
  # Усе тут — за ключем виховника, не за кодом Рою. Нічого не видаляє:
  # «прибрати» лише ховає, «злити» ховає й перенаправляє записи.

  post "/api/lead" do
    roi = roi_by_key!(payload["key"])
    novaks = DB[:novak].where(roi_id: roi[:id]).order(:nick_key).all
    names  = novaks.to_h { |n| [n[:id], n[:nick]] }
    json(
      roi:    { name: roi[:name], code: roi[:code], test: roi[:test] },
      novaks: novaks.map do |n|
        { id: n[:id], nick: n[:nick], codes: n[:codes].to_a, hidden: n[:hidden],
          merged_into: names[n[:alias_of]], updated_at: n[:updated_at].iso8601 }
      end
    )
  end

  post "/api/lead/hide" do
    roi = roi_by_key!(payload["key"])
    row = novak_in!(roi, payload["id"])
    hidden = payload["hidden"] ? true : false
    # Повернути злитого — означає й розв'язати злиття; справи, вже
    # перенесені в інший рядок, там і лишаються.
    upd = hidden ? { hidden: true } : { hidden: false, alias_of: nil }
    DB[:novak].where(id: row[:id]).update(upd)
    json(ok: true)
  end

  post "/api/lead/merge" do
    roi  = roi_by_key!(payload["key"])
    from = novak_in!(roi, payload["from"])
    into = novak_in!(roi, payload["into"])
    fail!(422, "не можна злити новака із самим собою") if from[:id] == into[:id]
    fail!(422, "цього новака вже злито") if into[:alias_of]

    DB.transaction do
      DB.fetch(<<~SQL, from[:id], into[:id]).all
        update novak
           set codes = (
                 select coalesce(jsonb_agg(distinct e), '[]'::jsonb)
                 from jsonb_array_elements(novak.codes || (select codes from novak where id = ?)) e
               ),
               updated_at = now()
         where id = ?
        returning id
      SQL
      DB[:novak].where(alias_of: from[:id]).update(alias_of: into[:id])
      DB[:novak].where(id: from[:id]).update(hidden: true, alias_of: into[:id])
    end
    json(ok: true)
  end

  # Тестовий Рій стає справжнім. Назад — лише руками в psql.
  post "/api/lead/real" do
    roi = roi_by_key!(payload["key"])
    DB[:roi].where(id: roi[:id]).update(test: false)
    json(ok: true)
  end

  # ──────────────── відгуки ────────────────

  # Виховники оцінюють справи перед тим, як дати гру новакам. Тільки з
  # тестового Рою: у справжньому діти цього не бачать і не шлють.
  # Відгук на справу оновлюється, загальний (без deed) — дописується.
  post "/api/feedback" do
    roi = roi_by_code!(payload["code"])
    fail!(403, "відгуки приймаємо лише з тестового Рою") unless roi[:test]
    nick = clean(payload["nick"])
    fail!(422, "потрібне прізвисько") if nick.empty?

    deed = payload["deed"]&.to_s
    fail!(422, "невідома справа") if deed && !deed.match?(DEED_RE)
    mark = payload["mark"]&.to_s
    fail!(422, "невідома оцінка") if mark && !MARKS.include?(mark)
    note = clean(payload["note"], 500)
    fail!(422, "порожній відгук") if mark.nil? && note.empty?

    row = { roi_id: roi[:id], nick: nick, nick_key: nick_key(nick), deed: deed,
            title: clean(payload["title"], 80), mark: mark, note: note }
    if deed
      DB[:vidguk].insert_conflict(
        target: %i[roi_id nick_key deed],
        update: { nick: Sequel[:excluded][:nick], title: Sequel[:excluded][:title],
                  mark: Sequel[:excluded][:mark], note: Sequel[:excluded][:note],
                  updated_at: Sequel::CURRENT_TIMESTAMP }
      ).insert(row)
    else
      DB[:vidguk].insert(row)
    end
    json(ok: true)
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
