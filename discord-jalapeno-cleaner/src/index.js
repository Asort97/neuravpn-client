import 'dotenv/config';
import {
  Client,
  Events,
  GatewayIntentBits,
  PermissionFlagsBits,
} from 'discord.js';

const config = {
  token: process.env.DISCORD_TOKEN?.trim(),
  guildId: process.env.GUILD_ID?.trim() || null,
  targetAppId: process.env.TARGET_APP_ID?.trim() || null,
  targetAppName: (process.env.TARGET_APP_NAME?.trim() || 'Jalapeno').toLocaleLowerCase(),
  deleteHistory: parseBoolean(process.env.DELETE_HISTORY, true),
  maxMessagesPerChannel: parseNonNegativeInteger(
    process.env.MAX_MESSAGES_PER_CHANNEL,
    0,
  ),
};

if (!config.token) {
  console.error('Ошибка: укажите DISCORD_TOKEN в файле .env');
  process.exit(1);
}

if (!config.targetAppId) {
  console.warn(
    `TARGET_APP_ID не задан. Используется запасной фильтр по имени "${config.targetAppName}".`,
  );
}

const client = new Client({
  intents: [GatewayIntentBits.Guilds, GatewayIntentBits.GuildMessages],
});

let totalDeleted = 0;

function parseBoolean(value, fallback) {
  if (value == null || value.trim() === '') return fallback;
  return value.trim().toLocaleLowerCase() === 'true';
}

function parseNonNegativeInteger(value, fallback) {
  if (value == null || value.trim() === '') return fallback;
  const parsed = Number.parseInt(value, 10);
  return Number.isInteger(parsed) && parsed >= 0 ? parsed : fallback;
}

function isTargetMessage(message) {
  if (!message.inGuild() || !message.author?.bot) return false;

  if (config.targetAppId) {
    return (
      message.applicationId === config.targetAppId ||
      message.author.id === config.targetAppId
    );
  }

  const names = [
    message.author.username,
    message.author.globalName,
  ]
    .filter(Boolean)
    .map((name) => name.toLocaleLowerCase());

  return names.includes(config.targetAppName);
}

function isSelectedGuild(guildId) {
  return config.guildId === null || config.guildId === guildId;
}

function canCleanChannel(channel) {
  if (!channel?.isTextBased() || !channel.messages || !channel.guild) {
    return false;
  }

  const permissions = channel.permissionsFor(channel.guild.members.me);
  return Boolean(
    permissions?.has([
      PermissionFlagsBits.ViewChannel,
      PermissionFlagsBits.ReadMessageHistory,
      PermissionFlagsBits.ManageMessages,
    ]),
  );
}

async function deleteTargetMessage(message, source) {
  if (!isTargetMessage(message)) return false;

  try {
    await message.delete();
    totalDeleted += 1;

    const invokedBy = message.interactionMetadata?.user;
    const invoker = invokedBy
      ? `; вызвал ${invokedBy.tag} (${invokedBy.id})`
      : '';

    console.log(
      `Удалено ${source}: #${message.channel.name ?? message.channelId} ` +
        `(${message.channelId}), сообщение ${message.id}${invoker}`,
    );
    return true;
  } catch (error) {
    console.error(
      `Не удалось удалить сообщение ${message.id} в ${message.channelId}:`,
      error.message,
    );
    return false;
  }
}

async function cleanChannelHistory(channel) {
  if (!canCleanChannel(channel)) {
    console.warn(
      `Пропуск #${channel?.name ?? channel?.id}: не хватает View Channel, ` +
        'Read Message History или Manage Messages.',
    );
    return;
  }

  console.log(`Проверяю #${channel.name ?? channel.id} (${channel.id})...`);

  let before;
  let scanned = 0;
  let deleted = 0;

  while (
    config.maxMessagesPerChannel === 0 ||
    scanned < config.maxMessagesPerChannel
  ) {
    const remaining =
      config.maxMessagesPerChannel === 0
        ? 100
        : Math.min(100, config.maxMessagesPerChannel - scanned);

    let messages;
    try {
      messages = await channel.messages.fetch({
        limit: remaining,
        before,
        cache: false,
      });
    } catch (error) {
      console.error(
        `Не удалось прочитать #${channel.name ?? channel.id}:`,
        error.message,
      );
      return;
    }

    if (messages.size === 0) break;

    scanned += messages.size;
    before = messages.last().id;

    const targets = messages.filter(isTargetMessage);
    if (targets.size > 0) {
      const results = await Promise.allSettled(
        targets.map((message) => deleteTargetMessage(message, 'из истории')),
      );
      deleted += results.filter(
        (result) => result.status === 'fulfilled' && result.value,
      ).length;
    }

    if (messages.size < remaining) break;
  }

  console.log(
    `Готово #${channel.name ?? channel.id}: проверено ${scanned}, удалено ${deleted}.`,
  );
}

async function collectTextChannels(guild) {
  const channels = new Map();

  const guildChannels = await guild.channels.fetch();
  for (const channel of guildChannels.values()) {
    if (channel?.isTextBased() && channel.messages) {
      channels.set(channel.id, channel);
    }
  }

  for (const channel of guildChannels.values()) {
    if (!channel?.threads?.fetchArchived) continue;

    try {
      const archivedThreads = await channel.threads.fetchArchived(
        { type: 'public', fetchAll: true },
        false,
      );
      for (const thread of archivedThreads.threads.values()) {
        channels.set(thread.id, thread);
      }
    } catch (error) {
      console.warn(
        `Не удалось получить архивные ветки #${channel.name ?? channel.id}: ` +
          error.message,
      );
    }
  }

  try {
    const activeThreads = await guild.channels.fetchActiveThreads();
    for (const thread of activeThreads.threads.values()) {
      channels.set(thread.id, thread);
    }
  } catch (error) {
    console.warn(`Не удалось получить активные ветки: ${error.message}`);
  }

  return channels.values();
}

async function cleanGuild(guild) {
  console.log(`Начинаю очистку сервера "${guild.name}" (${guild.id}).`);

  let channels;
  try {
    channels = await collectTextChannels(guild);
  } catch (error) {
    console.error(`Не удалось получить каналы сервера ${guild.id}:`, error.message);
    return;
  }

  for (const channel of channels) {
    await cleanChannelHistory(channel);
  }
}

client.once(Events.ClientReady, async (readyClient) => {
  console.log(`Бот запущен как ${readyClient.user.tag} (${readyClient.user.id}).`);
  console.log('Новые сообщения Jalapeno теперь удаляются автоматически.');

  if (!config.deleteHistory) return;

  const guilds = readyClient.guilds.cache.filter((guild) =>
    isSelectedGuild(guild.id),
  );

  if (config.guildId && guilds.size === 0) {
    console.error(
      `Сервер GUILD_ID=${config.guildId} не найден. Проверьте ID и приглашение бота.`,
    );
    return;
  }

  for (const guild of guilds.values()) {
    await cleanGuild(guild);
  }

  console.log(
    `Первичная очистка завершена. Всего удалено: ${totalDeleted}. ` +
      'Бот остаётся запущенным и следит за новыми сообщениями.',
  );
});

client.on(Events.MessageCreate, async (message) => {
  if (!isSelectedGuild(message.guildId) || !isTargetMessage(message)) return;
  await deleteTargetMessage(message, 'новое');
});

client.on(Events.Error, (error) => {
  console.error('Ошибка Discord-клиента:', error);
});

process.on('SIGINT', async () => {
  console.log('\nОстанавливаю бота...');
  client.destroy();
  process.exit(0);
});

await client.login(config.token);
