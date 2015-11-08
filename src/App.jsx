import React from 'react';
import SplitPane from 'react-split-pane';
import App from 'react-toolbox/lib/app/index';
import AppBar from 'react-toolbox/lib/app_bar/index';
import Button from 'react-toolbox/lib/button/index';
import NimEditor from './NimEditor';

require('./ReactSplitPane.css');

export default class Application extends React.Component {
  render() {
    return (
      <div>
        <AppBar flat>
          <Button accent label="Compile"/>
        </AppBar>
        <SplitPane split="vertical" minSize="50">
          <NimEditor/>
          <SplitPane split="horizontal">
            <div>Top</div>
            <div>Bottom</div>
          </SplitPane>
        </SplitPane>
      </div>
    );
  }
}
