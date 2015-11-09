import React from 'react';

import AppBar from 'react-toolbox/lib/app_bar/index';
import Button from 'react-toolbox/lib/button/index';

export default class ToolBar extends React.Component {
  static contextTypes = {
    workerEmitter: React.PropTypes.any,
  };

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
    console.log("run clicked");
  }
}
