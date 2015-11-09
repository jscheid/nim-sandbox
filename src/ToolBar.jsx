import React from 'react';

import AppBar from 'react-toolbox/lib/app_bar/index';
import Button from 'react-toolbox/lib/button/index';

export default class ToolBar extends React.Component {
  static contextTypes = {
    workerEmitter: React.PropTypes.any,
  };

  constructor(props) {
    super(props);
    this.state = {
      code: '',
    };
  }

  componentDidMount() {
    this.context.workerEmitter.on('compilation', code => {
      this.setState({ code });
    });
  }

  render() {
    return (
      <AppBar flat style={{ flexGrow: 0, flexShrink: 0 }}>
        <Button
          accent
          label="Compile"
          onClick={::this.handleCompileClicked}
        />
        <Button
          accent
          label="Run"
          onClick={::this.handleRunClicked}
        />
      </AppBar>
    );
  }

  handleCompileClicked() {
    this.context.workerEmitter.emit('startCompilation');
  }

  handleRunClicked() {
    const emitter = this.context.workerEmitter;
    emitter.emit('clearOutput');
    const rawEcho = 'function rawEcho() { for (var i = 0; i < arguments.length; ++i) emitter.emit("output", toJSStr(arguments[i])); }';
    eval(rawEcho + this.state.code.replace('function rawEcho', 'function _rawEcho'));
  }
}
