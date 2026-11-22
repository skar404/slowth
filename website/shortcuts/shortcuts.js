(() => {
  const service = document.body.dataset.service;
  if (!['instagram', 'youtube', 'tiktok', 'facebook', 'x'].includes(service)) return;
  const name = document.body.dataset.name;
  const ru = navigator.language.toLowerCase().startsWith('ru');
  if (ru) {
    document.documentElement.lang = 'ru';
    const copy = {
      title: `Добавьте ${name} на экран «Домой»`,
      intro: 'Привычная иконка откроет сайт внутри Slowth с вашими настройками блокировки.',
      step1: 'Откройте эту страницу в Safari и нажмите «Поделиться».',
      step2: 'Выберите «На экран Домой». Если есть переключатель «Открывать как веб-приложение», оставьте его включённым.',
      step3: 'Нажмите «Добавить». Название и иконка уже подготовлены.',
      launchTitle: `Открыть ${name} в Slowth`,
      launchHint: 'Если Slowth не открылся, нажмите кнопку ниже. iOS может запросить подтверждение.',
      open: 'Открыть в Slowth',
      note: 'Нужен Slowth с функцией «Веб-приложения» и iOS 18.4 или новее. Аккаунты внутри Slowth и Safari хранятся отдельно.',
      remove: 'Удаление ярлыка не удаляет аккаунт и настройки Slowth.',
      install: 'Установить Slowth',
      setup: 'Инструкция по установке'
    };
    for (const [id, text] of Object.entries(copy)) document.getElementById(id).textContent = text;
  }
  const standalone = navigator.standalone === true || matchMedia('(display-mode: standalone)').matches;
  const params = new URLSearchParams(location.search);
  const launching = params.get('setup') !== '1' && (standalone || params.get('launch') === '1');
  const openLink = document.getElementById('open');
  openLink.href = `slowth://web/${service}`;
  if (launching) {
    document.getElementById('instructions').hidden = true;
    document.getElementById('launcher').hidden = false;
    // One attempt per document. Returning from Slowth must not create a redirect loop.
    if (standalone) location.href = openLink.href;
  }
})();
