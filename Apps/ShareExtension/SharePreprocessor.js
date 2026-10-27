var ExtensionPreprocessingJS = new function () {
  this.run = function (arguments) {
    arguments.completionFunction({title: document.title, url: document.URL, text: (document.body ? document.body.innerText : '').slice(0, 200000)});
  };
};
