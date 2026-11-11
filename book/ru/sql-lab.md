---
group: appendices
status: translated
related: []
source_rev: 06a9daa8c6399ee38294f8c89f3ec170aeaf385d
---

# Практикум SQL

Практикум SQL объясняет, как запускать примеры книги. Полные скрипты каждой главы находятся рядом с книгой и содержат версию PostgreSQL, на которой их проверяли, поэтому вы можете создать схему, выполнить операции и самостоятельно увидеть ошибки ограничений. Приложение описывает запуск локального экземпляра PostgreSQL и организацию скриптов.

## Что понадобится

У каждой из 52 глав о паттернах и антипаттернах есть скрипт `book/assets/<slug>/<slug>.sql`. В заголовках указана проверенная версия PostgreSQL 18.6. Используйте сервер PostgreSQL 18 и его клиент `psql`: примеры включают `uuidv7()`, временные ключи, диапазоны PostgreSQL, PL/pgSQL и команды `psql` с обратной косой чертой. Примечания о других движках в главах — рекомендации по переносу, а не утверждение, что эти файлы выполняются там без изменений.

Используйте одноразовый кластер с подключением суперпользователя. Некоторые примеры создают роли, меняют разрешения и устанавливают поставляемые расширения `ltree` или `btree_gist`. Примеры изоляции арендаторов также создают роли входа без паролей, а «База арендатора» создаёт `dt_a` и `dt_b` и переподключается под своими рабочими ролями. Эти переподключения требуют локальной аутентификации trust, принятой в практикуме. Одна новая база не изолирует роли уровня кластера и дополнительные базы.

Команды ниже запускаются из корня репозитория. Выберите один вариант запуска сервера, затем выполните один пример или весь набор. Оставьте сообщения сервера на английском: некоторые скрипты сравнивают не только SQLSTATE, но и точный текст диагностики. Не отключайте `plpgsql.check_asserts`, чтобы проверки `ASSERT` выполнялись.

## Контейнер Docker с PostgreSQL 18

[Официальный образ PostgreSQL](https://hub.docker.com/_/postgres) содержит сервер и клиенты. Этот практикум не публикует порт, отключает сеть контейнера и хранит кластер во временной памяти; локальная аутентификация trust позволяет скриптам арендаторов переподключаться без паролей. Образы PostgreSQL 18 используют `/var/lib/postgresql` как путь тома.

```sh
docker run --detach --name ddp-sql-lab \
  --network none \
  --tmpfs /var/lib/postgresql \
  --env POSTGRES_HOST_AUTH_METHOD=trust \
  --mount "type=bind,source=$PWD,target=/book,readonly" \
  postgres:18

until docker exec ddp-sql-lab pg_isready -q -h 127.0.0.1 -U postgres; do
  sleep 1
done
docker exec ddp-sql-lab psql -X -U postgres -d postgres \
  -c 'SELECT version();'
```

Если готовность так и не наступила, посмотрите `docker logs ddp-sql-lab`. Репозиторий смонтирован только для чтения в `/book`; SQL-скрипты остаются обычными файлами, а не обработчиками инициализации. Например, запустите «Суррогатный ключ» в отдельной новой базе:

```sh
docker exec ddp-sql-lab createdb -U postgres --template=template0 lab_one
docker exec ddp-sql-lab psql -X -v ON_ERROR_STOP=1 -U postgres \
  -d lab_one -f /book/book/assets/surrogate-key/surrogate-key.sql
docker exec ddp-sql-lab dropdb -U postgres lab_one
```

Завершив все эксперименты, удалите контейнер и его временный кластер:

```sh
docker rm --force --volumes ddp-sql-lab
```

## Локальный одноразовый кластер

Установите полный серверный дистрибутив PostgreSQL 18, включая `initdb`, `pg_ctl`, `postgres`, клиенты и поставляемые расширения. Установка только клиента не позволяет создать кластер. Поместите каталог `bin` этого дистрибутива первым в `PATH`; ниже показан путь Homebrew на Apple Silicon. Для другой установки замените его каталогом исполняемых файлов PostgreSQL 18.

```sh
export PATH=/opt/homebrew/opt/postgresql@18/bin:$PATH
postgres --version
psql --version

lab_dir=$(mktemp -d /tmp/ddp.XXXXXX)
initdb -D "$lab_dir/data" -U postgres --locale=C --encoding=UTF8 \
  --auth-local=trust --auth-host=reject
pg_ctl -D "$lab_dir/data" -l "$lab_dir/server.log" \
  -o "-k $lab_dir -c listen_addresses=''" -w start

export PGHOST="$lab_dir" PGPORT=5432 PGUSER=postgres PGDATABASE=postgres
psql -X -c 'SELECT version();'
```

Выполняйте это от обычного пользователя операционной системы, не от root. [`initdb`](https://www.postgresql.org/docs/18/app-initdb.html) создаёт кластер и указанного суперпользователя базы данных; [`pg_ctl`](https://www.postgresql.org/docs/18/app-pg-ctl.html) запускает сервер и ждёт готовности. Короткий путь `/tmp` ограничивает длину имени Unix-сокета. Пустое `listen_addresses` отключает TCP; `PGHOST` выбирает каталог сокета, поэтому существующий сервер на TCP-порту 5432 не используется.

Сохраняйте оболочку и значение `lab_dir` до очистки. После примеров остановите сервер до удаления каталога:

```sh
pg_ctl -D "$lab_dir/data" -m fast -w stop
rm -rf -- "$lab_dir"
unset PGHOST PGPORT PGUSER PGDATABASE
```

## Запуск одного скрипта

С работающим локальным кластером и экспортированными переменными подключения создайте базу из `template0`, выполните файл и удалите базу:

```sh
createdb --maintenance-db=postgres --template=template0 lab_one
psql -X -v ON_ERROR_STOP=1 --dbname=lab_one \
  --file=book/assets/surrogate-key/surrogate-key.sql
dropdb --maintenance-db=postgres lab_one
```

[`psql -X`](https://www.postgresql.org/docs/18/app-psql.html) игнорирует файлы запуска, а `ON_ERROR_STOP=1` останавливает файл при неожиданных ошибках с ненулевым кодом завершения. Сохраняйте параметр, даже если большинство скриптов задают его сами. Не добавляйте `--single-transaction`: скрипты сами определяют границы транзакций, некоторые намеренно фиксируют изменения, а «База арендатора» выполняет `CREATE DATABASE` и переподключается.

Многие примеры в конце откатывают учебную транзакцию. Другие оставляют схемы и строки для изучения, поэтому для каждой попытки используйте новую базу, не предполагая повторяемость файла. Примеры арендаторов оставляют и объекты уровня кластера; для очистки используйте полный запускатель ниже либо после ручного выполнения удаляйте весь кластер. Последовательные операторы демонстрируют протоколы и утверждения; успешное выполнение файла само по себе не проверяет каждую гонку двух сеансов из главы.

## Ожидаемые ошибки

Строка `ERROR` иногда означает, что демонстрация успешна. Оценивайте её по соседней проверке ожидания и итоговому коду процесса, а не по поиску слова `ERROR` в выводе.

| Приём в скриптах | Что происходит | Что делает запуск неуспешным |
| --- | --- | --- |
| Точка сохранения и временное отключение `ON_ERROR_STOP` | Неверный оператор печатает ошибку; скрипт сохраняет `:SQLSTATE`, возвращает остановку при ошибках и откатывается к точке сохранения | Сохранённое состояние отличается от ожидаемого, в том числе если неверный оператор неожиданно успешен |
| Блок `DO` с именованным обработчиком исключения | Внутренний блок пытается выполнить неверную операцию, перехватывает лишь ожидаемое условие и печатает уведомление | Наружу выходит неожиданное исключение, проверяемая диагностика отличается или выходит явная ошибка после неожиданного успеха |
| Помощник `pg_temp.expect_error` в примерах антипаттернов | Динамический SQL выполняется в блоке исключений; диагностика стека получает состояние и сообщение | Состояние или точное сообщение отличаются; отсутствие исключения тоже проваливает сравнение |
| Утверждения и проверки результатов | `ASSERT`, явное `IF ... RAISE EXCEPTION` или запрос с последующими `\gset` и `\if` проверяют данные | Неудачная проверка вызывает исключение, намеренно вычисляет `1 / 0` или выполняет `\quit 1` |

Например, [скрипт «Суррогатного ключа»](../assets/surrogate-key/surrogate-key.sql) использует такую последовательность внутри учебной транзакции:

```sql
SAVEPOINT expected_error;
\set ON_ERROR_STOP off
INSERT INTO customer (customer_number, display_name)
VALUES ('C-204', 'Duplicate');
\set rejected_state :SQLSTATE
\set ON_ERROR_STOP on
ROLLBACK TO SAVEPOINT expected_error;
SELECT :'rejected_state' = '23505' AS rejected \gset
\if :rejected
\else
    \quit 1
\endif
```

Сохранённое состояние должно быть `23505` — нарушение уникальности. Оно запоминается до `ROLLBACK TO`, потому что последующий SQL меняет `:SQLSTATE`. `expected_error` — имя точки сохранения в нескольких скриптах, а не особая возможность PostgreSQL; другие файлы используют описательные имена вроде `rejected_operation`. Откат восстанавливает транзакцию, чтобы следующие проверки могли выполняться.

[Исключающая дуга](../assets/exclusive-arc/exclusive-arc.sql) вместо этого перехватывает `check_violation` или `foreign_key_violation` в блоках `DO` и печатает ожидаемый SQLSTATE. Намеренный `RAISE EXCEPTION` после операции не позволяет молча принять неожиданный успех. Некоторые обработчики также сравнивают `SQLERRM`. [Списки с разделителями](../assets/delimited-lists/delimited-lists.sql) определяют повторно используемый временный помощник, а [Таблица связей](../assets/association-table/association-table.sql) включает `ASSERT` для сохранённых строк и каскадных эффектов.

Таким образом, успешные проверки могут выдавать обычные ошибки, уведомления и результаты запросов в одном запуске. Ненулевой код `psql` означает неудачный запуск практикума, даже если раньше появлялись уведомления об ожидаемых ошибках. Если неизменённый скрипт падает из-за другого языка диагностики или версии сервера, это всё равно нужно исследовать; не подавляйте проверки ради успешного результата.

## Запуск всех скриптов

[Запускатель на POSIX shell](../assets/sql-lab/run-all.sh) использует `set -eu` и клиенты PostgreSQL из `PATH`. Адрес узла/сокета, порт, пользователя и другие параметры подключения он берёт из стандартных [переменных окружения PG](https://www.postgresql.org/docs/18/libpq-envars.html). `PGDATABASE` задаёт служебную базу, по умолчанию `postgres`; каждому скрипту явно выбирается новая база. Пример «База арендатора» также переподключается к `postgres`, поэтому сохраняйте её доступной.

Для локального кластера:

```sh
sh book/assets/sql-lab/run-all.sh
```

Для Docker выполните тот же файл внутри контейнера с установленными там клиентами и локальным сокетом:

```sh
docker exec \
  --env PGHOST=/var/run/postgresql --env PGUSER=postgres \
  --env PGDATABASE=postgres \
  ddp-sql-lab sh /book/book/assets/sql-lab/run-all.sh
```

Запускатель находит `book/assets/*/*.sql` в порядке путей независимо от рабочего каталога. Для каждого файла он создаёт базу с уникальным именем из `template0`, запускает `psql -X -v ON_ERROR_STOP=1`, удаляет базу и печатает `PASS <slug>`. Он останавливается при первом ненулевом завершении скрипта и печатает `FAIL <slug>`; обработчик выхода пытается очистить объекты при ошибке или прерывании. Ошибки очистки также делают запуск неуспешным. Если проходят все текущие файлы, последняя строка — `PASS: 52 scripts`.

Запускатель также удаляет вспомогательные базы примеров арендаторов (`dt_a`, `dt_b`) и роли (`ss_app`, `st_owner`, `st_app_a`, `st_app_b`, `dt_owner`, `dt_app_a`, `dt_app_b`). «Журнал аудита» создаёт `audit_example_app` внутри откатываемой транзакции. Предварительная проверка отклоняет любое из этих существующих имён до начала работы; она не использует и не удаляет уже имеющиеся учебные объекты. Выполняйте только один набор за раз в одноразовом кластере. После неперехватываемого завершения или ошибки очистки удалите кластер и начните с нового.

Полный набор успешно запускался на одноразовом кластере PostgreSQL 18.6: все 52 файла прошли с включёнными проверками. Пример outbox предполагает подтверждение брокера в SQL, не обращаясь к брокеру; примеры очереди и резервирования продвигают тестовое состояние вместо ожидания реальных сроков работников.

## Каталог скриптов

Группы и порядок глав следуют [оглавлению](SUMMARY.md) книги. Каждый файл самодостаточен для документированной учебной среды; предыдущая глава не является обязательной.

### Идентификация

| Глава | Скрипт | Демонстрация |
| --- | --- | --- |
| [Суррогатный ключ](surrogate-key.md) | [surrogate-key.sql](../assets/surrogate-key/surrogate-key.sql) | Стабильные внутренние ссылки при смене бизнес-номера; бизнес-уникальность и альтернативы UUID. |
| [Естественный ключ](natural-key.md) | [natural-key.sql](../assets/natural-key/natural-key.sql) | Составная идентичность позиции и каскадное исправление зависимых ссылок. |
| [Упорядоченный идентификатор](time-ordered-identifier.md) | [time-ordered-identifier.sql](../assets/time-ordered-identifier/time-ordered-identifier.sql) | Генерация UUIDv7, извлечение полей, явная вставка и отклонение дубликата. |
| [Публичный идентификатор](public-identifier.md) | [public-identifier.sql](../assets/public-identifier/public-identifier.sql) | Поиск и смена внешнего ID с сохранением внутренних ссылок. |

### Связи

| Глава | Скрипт | Демонстрация |
| --- | --- | --- |
| [Таблица связей](association-table.md) | [association-table.sql](../assets/association-table/association-table.sql) | Атрибуты участия, уникальность пары, FK концов и каскадные эффекты. |
| [Разделение таблицы](table-split.md) | [table-split.sql](../assets/table-split/table-split.sql) | Необязательные детали с общим ключом и отложенный вариант обязательного расширения. |
| [Упорядоченная коллекция](ordered-collection.md) | [ordered-collection.sql](../assets/ordered-collection/ordered-collection.sql) | Позиции с промежутками, перенумерация, обмен и уникальность в пределах владельца. |
| [Локализованные значения](localized-values.md) | [localized-values.sql](../assets/localized-values/localized-values.sql) | Строки переводов, обязательный перевод по умолчанию, его атомарная смена и поиск по языку. |

### Справочники и состояние

| Глава | Скрипт | Демонстрация |
| --- | --- | --- |
| [Таблица значений](lookup-table.md) | [lookup-table.sql](../assets/lookup-table/lookup-table.sql) | Поддерживаемые подписи статусов и защита выведенных значений; отдельные варианты enum/домена. |
| [История статусов](status-history.md) | [status-history.sql](../assets/status-history/status-history.sql) | Защищённые переходы, отклонение по ревизии и атомарная запись текущего состояния/истории. |

### Иерархии

| Глава | Скрипт | Демонстрация |
| --- | --- | --- |
| [Список смежности](adjacency-list.md) | [adjacency-list.sql](../assets/adjacency-list/adjacency-list.sql) | Рекурсивные потомки и цепочки предков, защищённое перемещение и удаление поддерева. |
| [Материализованный путь](materialized-path.md) | [materialized-path.sql](../assets/materialized-path/materialized-path.sql) | Включение `ltree` и транзакционная перезапись путей ветви с согласованностью родителя. |
| [Вложенные множества](nested-sets.md) | [nested-sets.sql](../assets/nested-sets/nested-sets.sql) | Вставка, перемещение и удаление плотных интервалов, затем аудит плотности и пересечений. |
| [Таблица замыканий](closure-table.md) | [closure-table.sql](../assets/closure-table/closure-table.sql) | Поддержка пар предков при перемещении/удалении и сравнение замыкания с прямыми рёбрами. |

### Типы и атрибуты

| Глава | Скрипт | Демонстрация |
| --- | --- | --- |
| [Единая таблица](single-table-inheritance.md) | [single-table-inheritance.sql](../assets/single-table-inheritance/single-table-inheritance.sql) | Проверки формы строки по дискриминатору и ссылки на всё семейство. |
| [Таблицы классов](class-table-inheritance.md) | [class-table-inheritance.sql](../assets/class-table-inheritance/class-table-inheritance.sql) | Отложенная полнота подтипов, отклонение неверного типа и атомарное преобразование. |
| [Таблицы конкретных классов](concrete-table-inheritance.md) | [concrete-table-inheritance.sql](../assets/concrete-table-inheritance/concrete-table-inheritance.sql) | Отдельные полные типы, общая выдача ID, чтение объединения и FK конкретных подтипов. |
| [Исключающая дуга](exclusive-arc.md) | [exclusive-arc.sql](../assets/exclusive-arc/exclusive-arc.sql) | Ровно одна реальная цель, передача владения и поведение при удалении цели. |
| [Столбец JSON](json-column.md) | [json-column.sql](../assets/json-column/json-column.sql) | Проверка/индексирование путей документа и версия для редактирования всего документа. |
| [Типизированные свойства](typed-properties.md) | [typed-properties.sql](../assets/typed-properties/typed-properties.sql) | Публикация профилей свойств, проверка типов/полноты и миграция профиля товара. |

### Время и удаление

| Глава | Скрипт | Демонстрация |
| --- | --- | --- |
| [Таблица истории](history-table.md) | [history-table.sql](../assets/history-table/history-table.sql) | Запись версий строк, запрос прошлого, запрет повторного использования идентичности и срок хранения. |
| [Период действия](effective-dating.md) | [effective-dating.sql](../assets/effective-dating/effective-dating.sql) | Непересекающиеся бизнес-периоды, выбор на момент времени и ссылки с временным покрытием. |
| [Битемпоральная таблица](bitemporal-table.md) | [bitemporal-table.sql](../assets/bitemporal-table/bitemporal-table.sql) | Исправление бизнес-истории с сохранением прежних записанных представлений и защитой от пересечений. |
| [Журнал аудита](audit-log.md) | [audit-log.sql](../assets/audit-log/audit-log.sql) | Атомарные действия с авторством и рабочие разрешения, запрещающие переписывать свидетельства. |
| [Мягкое удаление](soft-delete.md) | [soft-delete.sql](../assets/soft-delete/soft-delete.sql) | Уникальность живых строк, сохранённые ссылки, конфликт восстановления и защита от физического удаления. |

### Структуры предметной области

| Глава | Скрипт | Демонстрация |
| --- | --- | --- |
| [Участник](party.md) | [party.sql](../assets/party/party.sql) | Общая идентичность контрагента, типизированные расширения и уникальность регистрации. |
| [Объект роли](role-object.md) | [role-object.sql](../assets/role-object/role-object.sql) | Датированные эпизоды участия, типизированные ссылки на роли и отклонение конфликтующих периодов. |
| [Величина](quantity.md) | [quantity.sql](../assets/quantity/quantity.sql) | Совместимые пересчёты множителями, проверка размерности и отказ в пересчёте валют. |
| [Наблюдение](observation.md) | [observation.sql](../assets/observation/observation.sql) | Неизменяемые типизированные свидетельства, замены, отклонения и вычисляемый статус наблюдения. |
| [Состав изделия](bill-of-materials.md) | [bill-of-materials.sql](../assets/bill-of-materials/bill-of-materials.sql) | Выпуск/закрепление версий рецептуры, развёртка количеств путей и выбор выпуска по бизнес-дате. |
| [Двойная запись](double-entry-ledger.md) | [double-entry-ledger.sql](../assets/double-entry-ledger/double-entry-ledger.sql) | Сбалансированная атомарная запись, неизменяемые проводки, проверки валюты и точное сторнирование. |

### Надёжная запись

| Глава | Скрипт | Демонстрация |
| --- | --- | --- |
| [Столбец версии](version-column.md) | [version-column.sql](../assets/version-column/version-column.sql) | Условные обновления отклоняют устаревшие снимки и повышают версию агрегата. |
| [Резервирование](reservation.md) | [reservation.sql](../assets/reservation/reservation.sql) | Защита от пересечения слотов и удержание общего запаса, подтверждение, отмена и истечение. |
| [Запись идемпотентности](idempotency-record.md) | [idempotency-record.sql](../assets/idempotency-record/idempotency-record.sql) | Возврат сохранённого результата, отклонение изменённого содержимого и дедупликация эффекта потребителя. |
| [Транзакционный outbox](transactional-outbox.md) | [transactional-outbox.sql](../assets/transactional-outbox/transactional-outbox.sql) | Атомарная промежуточная запись производителя, упорядоченное подтверждение ретранслятора и откат неудачного создания. |
| [Таблица очереди](queue-table.md) | [queue-table.sql](../assets/queue-table/queue-table.sql) | Захват, поколения аренды, устаревшие подтверждения, продление, восстановление и исчерпание попыток. |

### Изоляция арендаторов

| Глава | Скрипт | Демонстрация |
| --- | --- | --- |
| [Общая схема](shared-schema.md) | [shared-schema.sql](../assets/shared-schema/shared-schema.sql) | FK в области арендатора, RLS ограниченной роли и сброс контекста транзакции. |
| [Схема арендатора](schema-per-tenant.md) | [schema-per-tenant.sql](../assets/schema-per-tenant/schema-per-tenant.sql) | Раздельные разрешения, маршрутизация в пределах транзакции и отметки миграций каждой схемы. |
| [База арендатора](database-per-tenant.md) | [database-per-tenant.sql](../assets/database-per-tenant/database-per-tenant.sql) | Подготовка двух баз и учётных данных, проверка идентичности назначения и запрет доступа между базами. |

### Рост и изменения

| Глава | Скрипт | Демонстрация |
| --- | --- | --- |
| [Таблица итогов](summary-table.md) | [summary-table.sql](../assets/summary-table/summary-table.sql) | Поддержка дельт, сверка расхождений, пересборка итогов и обновление материализованного представления. |
| [Секционирование таблицы](table-partitioning.md) | [table-partitioning.sql](../assets/table-partitioning/table-partitioning.sql) | Маршрутизация диапазонов, составные ключи, отсутствующие секции и отсоединение/присоединение данных. |
| [Расширение и свёртывание](expand-contract.md) | [expand-contract.sql](../assets/expand-contract/expand-contract.sql) | Мост между старым и новым контрактами при переименовании, разделении таблицы и смене типа. |

### Антипаттерны

| Глава | Скрипт | Демонстрация |
| --- | --- | --- |
| [Списки с разделителями](delimited-lists.md) | [delimited-lists.sql](../assets/delimited-lists/delimited-lists.sql) | Ошибки поиска подстрок, разбор импортированных участников и карантин неизвестных ID. |
| [Обязательные суррогаты](mandatory-surrogates.md) | [mandatory-surrogates.sql](../assets/mandatory-surrogates/mandatory-surrogates.sql) | Восстановление идентичности пары с сохранением соответствия старых ID и альтернативой уникальной пары. |
| [Отсутствующие внешние ключи](missing-foreign-keys.md) | [missing-foreign-keys.sql](../assets/missing-foreign-keys/missing-foreign-keys.sql) | Карантин осиротевших строк, контроль новых ссылок и проверка существующих строк. |
| [Повторяющиеся столбцы](repeated-columns.md) | [repeated-columns.sql](../assets/repeated-columns/repeated-columns.sql) | Преобразование нумерованных позиций в строки участия с ограничениями. |
| [Полиморфные связи](polymorphic-associations.md) | [polymorphic-associations.sql](../assets/polymorphic-associations/polymorphic-associations.sql) | Замена непроверяемых пар «вид/ID» проверенной исключающей дугой. |
| [Нетипизированные свойства](untyped-properties.md) | [untyped-properties.sql](../assets/untyped-properties/untyped-properties.sql) | Аудит преобразований, карантин неверных свойств и заполнение типизированных столбцов с ограничениями. |
| [Изменчивые перечисления](volatile-enums.md) | [volatile-enums.sql](../assets/volatile-enums/volatile-enums.sql) | Перенос словаря схемы в поддерживаемые строки справочника с сохранением ссылок. |
| [Фиксированная глубина](fixed-depth-queries.md) | [fixed-depth-queries.sql](../assets/fixed-depth-queries/fixed-depth-queries.sql) | Сравнение обрезанных соединений с рекурсивным обходом и сохранение целостности родителя. |
| [Клонированные таблицы](cloned-tables.md) | [cloned-tables.sql](../assets/cloned-tables/cloned-tables.sql) | Объединение таблиц по датам с проверенным соответствием идентификаторов и одним отношением с ограничениями. |
| [Неточная арифметика](inexact-arithmetic.md) | [inexact-arithmetic.sql](../assets/inexact-arithmetic/inexact-arithmetic.sql) | Проверка приближённых сумм, переход на точные десятичные и отклонение неверного масштаба/неконечных значений. |
